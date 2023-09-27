# frozen_string_literal: true

require "yarp"

module ActionView
  class RenderParser # :nodoc:
    ALL_KNOWN_KEYS = [:partial, :template, :layout, :formats, :locals, :object, :collection, :as, :status, :content_type, :location, :spacer_template]
    RENDER_TYPE_KEYS = [:partial, :template, :layout]

    def initialize(name, code)
      @name = name
      @code = code
    end

    def render_calls
      queue = [YARP.parse(@code).value]
      templates = []

      while (node = queue.shift)
        queue.concat(node.compact_child_nodes)
        next unless node.is_a?(YARP::CallNode)

        options = render_call_options(node)
        next unless options

        render_type = (options.keys & RENDER_TYPE_KEYS)[0]
        template, object_template = render_call_template(options[render_type])
        next unless template

        if options.key?(:object) || options.key?(:collection) || object_template
          next if options.key?(:object) && options.key?(:collection)
          next unless options.key?(:partial)
        end

        if options[:spacer_template].is_a?(YARP::StringNode)
          templates << partial_to_virtual_path(:partial, options[:spacer_template].unescaped)
        end

        templates << partial_to_virtual_path(render_type, template)

        if render_type != :layout && options[:layout].is_a?(YARP::StringNode)
          templates << partial_to_virtual_path(:layout, options[:layout].unescaped)
        end
      end

      templates
    end

    private
      # Accept a call node and return a hash of options for the render call. If
      # it doesn't match the expected format, return nil.
      def render_call_options(node)
        # We are only looking for calls to render or render_to_string.
        name = node.name.to_sym
        return if name != :render && name != :render_to_string

        # We are only looking for calls with arguments.
        arguments = node.arguments
        return unless arguments

        arguments = arguments.arguments
        length = arguments.length

        # Get rid of any parentheses to get directly to the contents.
        arguments.map! do |argument|
          current = argument

          while current.is_a?(YARP::ParenthesesNode) &&
                current.body.is_a?(YARP::StatementsNode) &&
                current.body.body.length == 1
            current = current.body.body.first
          end

          current
        end

        # We are only looking for arguments that are either a string with an
        # array of locals or a keyword hash with symbol keys.
        options =
          if (length == 1 || length == 2) && !arguments[0].is_a?(YARP::KeywordHashNode)
            { partial: arguments[0], locals: arguments[1] }
          elsif length == 1 &&
                arguments[0].is_a?(YARP::KeywordHashNode) &&
                arguments[0].elements.all? do |element|
                  element.is_a?(YARP::AssocNode) && element.key.is_a?(YARP::SymbolNode)
                end
            arguments[0].elements.to_h do |element|
              [element.key.unescaped.to_sym, element.value]
            end
          end

        return unless options

        # Here we validate that the options have the keys we expect.
        keys = options.keys
        return if (keys & RENDER_TYPE_KEYS).empty?
        return if (keys - ALL_KNOWN_KEYS).any?

        # Finally, we can return a valid set of options.
        options
      end

      # Accept the node that is being passed in the position of the template and
      # return the template name and whether or not it is an object template.
      def render_call_template(node)
        object_template = false
        template =
          if node.is_a?(YARP::StringNode)
            path = node.unescaped
            path.include?("/") ? path : "#{File.dirname(@name)}/#{path}"
          else
            dependency =
              case node
              when YARP::ClassVariableReadNode
                node.slice[2..]
              when YARP::InstanceVariableReadNode
                node.slice[1..]
              when YARP::GlobalVariableReadNode
                node.slice[1..]
              when YARP::LocalVariableReadNode
                node.slice
              when YARP::CallNode
                node.name
              else
                return
              end

            "#{dependency.pluralize}/#{dependency.singularize}"
          end

        [template, object_template]
      end

      def partial_to_virtual_path(render_type, partial_path)
        if render_type == :partial || render_type == :layout
          partial_path.gsub(%r{(/|^)([^/]*)\z}, '\1_\2')
        else
          partial_path
        end
      end
  end
end
