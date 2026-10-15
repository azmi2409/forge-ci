# frozen_string_literal: true

module ForgeCIRunner
  # Idle poll backoff. Pure timing logic — the caller sleeps.
  #
  #   backoff = Backoff.new(base: 5.0, max: 60.0, factor: 2.0)
  #   sleep backoff.tick   # => 5.0, then 10.0, 20.0, 40.0, 60.0, 60.0, ...
  #   backoff.reset        # => back to 5.0 after a successful claim
  class Backoff
    attr_reader :current

    def initialize(base: 5.0, max: 60.0, factor: 2.0)
      @base = base.to_f
      @max = max.to_f
      @factor = factor.to_f
      @current = @base
    end

    # Returns the interval to sleep now, then advances to the next one.
    def tick
      interval = @current
      @current = [@current * @factor, @max].min
      interval
    end

    def reset
      @current = @base
    end
  end
end
