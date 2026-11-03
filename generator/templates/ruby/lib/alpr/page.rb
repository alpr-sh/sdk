# frozen_string_literal: true

module Alpr
  # One page of a list: its items, and the cursor of the next page.
  class Page
    # @return [Array] the items of the page
    attr_reader :items
    # @return [String, nil] the cursor to ask the next page with; nil on the last page
    attr_reader :next_cursor

    def initialize(items:, next_cursor:)
      @items = items.freeze
      @next_cursor = next_cursor.nil? || next_cursor.to_s.empty? ? nil : next_cursor.to_s
      freeze
    end

    # Builds a page from the API's hash ({"data": [...], "next": cursor}), each
    # item through the block.
    def self.from_hash(data, next_key = "next", &item)
      new(items: (data["data"] || []).map(&item), next_cursor: data[next_key])
    end

    # Walks pages from the cursor +first+ (the newest page when nil) until the
    # last one, yielding every item and ending at the first error; +fetch+
    # answers the Page of the cursor it is given. A cursor that does not move
    # would ask for the same page forever, so it ends the walk too.
    def self.iterate(first, &fetch)
      Enumerator.new do |yielder|
        cursor = first.nil? || first.to_s.empty? ? nil : first.to_s
        loop do
          result = fetch.call(cursor)
          result.items.each { |item| yielder << item }
          break if result.next_cursor.nil? || result.next_cursor == cursor

          cursor = result.next_cursor
        end
      end
    end
  end
end
