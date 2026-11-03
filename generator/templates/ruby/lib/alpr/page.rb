# frozen_string_literal: true

module Alpr
  # One page of a list, and where the list ends.
  class Page
    attr_reader :items, :pagination

    def initialize(items:, pagination:)
      @items = items.freeze
      @pagination = pagination
      freeze
    end

    # Builds a page from the API's hash, each item through the block.
    def self.from_hash(data, &item)
      new(items: (data["items"] || []).map(&item), pagination: Pagination.from_hash(data.fetch("pagination")))
    end

    # Walks pages from +first+ until the last one, as Polar's SDKs do, yielding
    # every item; +fetch+ answers the page it is given.
    def self.iterate(first, &fetch)
      Enumerator.new do |yielder|
        page = [first || 1, 1].max
        loop do
          result = fetch.call(page)
          result.items.each { |item| yielder << item }
          break if page >= result.pagination.max_page

          page += 1
        end
      end
    end
  end
end
