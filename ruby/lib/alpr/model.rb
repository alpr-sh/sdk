# frozen_string_literal: true

module Alpr
  # What every resource and every body shares: its members, read as a hash and
  # compared by value.
  module Value
    def to_h
      self.class::MEMBERS.to_h { |name| [name, instance_variable_get(:"@#{name}")] }
    end

    def ==(other)
      other.class == self.class && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    def inspect
      "#<#{self.class.name} #{to_h.map { |name, value| "#{name}=#{value.inspect}" }.join(", ")}>"
    end
    alias to_s inspect
  end

  # A resource the API answers, built from its JSON and frozen.
  class Model
    include Value
  end

  # The body of a write: built with keyword arguments, sent with the API's
  # names, an optional field left unset left out.
  class Params
    include Value

    # The params as they are, or built from a hash of their names.
    def self.coerce(params)
      case params
      when self then params
      when Hash then new(**params.transform_keys(&:to_sym))
      else raise ArgumentError, "alpr: #{name} is built from a Hash, not #{params.class}"
      end
    end
  end
end
