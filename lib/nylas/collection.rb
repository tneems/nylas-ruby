# frozen_string_literal: true

module Nylas
  # An enumerable for working with index and search endpoints
  class Collection
    attr_accessor :model, :api, :constraints

    extend Forwardable
    def_delegators :each, :map, :select, :reject, :to_a, :take
    def_delegators :to_a, :first, :last, :[]

    def initialize(model:, api:, constraints: nil)
      self.constraints = Constraints.from_constraints(constraints)
      self.model = model
      self.api = api
    end

    # Instantiates a new model
    def new(**attributes)
      model.new(attributes.merge(api: api))
    end

    def create(**attributes)
      instance = model.new(**attributes.merge(api: api))
      instance.save
      instance
    end

    # Merges in additional filters when querying the collection
    # @return [Collection<Model>]
    def where(filters)
      raise ModelNotFilterableError, model unless model.filterable?

      self.class.new(model: model, api: api, constraints: constraints.merge(where: filters))
    end

    def search(query)
      raise ModelNotSearchableError, model unless model.searchable?

      SearchCollection.new(model: model, api: api, constraints: constraints.merge(where: { q: query }))
    end

    # The collection now returns a string representation of the model in a particular mime type instead of
    # Model objects
    # @return [Collection<String>]
    def raw
      raise ModelNotAvailableAsRawError, model unless model.exposable_as_raw?

      self.class.new(model: model, api: api, constraints: constraints.merge(accept: model.raw_mime_type))
    end

    # @return [Integer]
    def count
      self.class.new(model: model, api: api, constraints: constraints.merge(view: "count")).execute[:count]
    end

    # @return [Collection<Model>]
    def expanded
      self.class.new(model: model, api: api, constraints: constraints.merge(view: "expanded"))
    end

    # @return [Array<String>]
    def ids
      self.class.new(model: model, api: api, constraints: constraints.merge(view: "ids")).execute
    end

    # Iterates over a single page of results based upon current pagination settings
    def each
      return enum_for(:each) unless block_given?

      execute.each do |result|
        yield(model.new(**result.merge(api: api)))
      end
    end

    def limit(quantity)
      self.class.new(model: model, api: api, constraints: constraints.merge(limit: quantity))
    end

    def offset(start)
      self.class.new(model: model, api: api, constraints: constraints.merge(offset: start))
    end

    # Iterates over every result that meets the filters, retrieving a page at a time
    def find_each
      return enum_for(:find_each) unless block_given?

      query = self
      accumulated = 0

      while query
        results = query.each do |instance|
          yield(instance)
        end

        accumulated += results.length
        query = query.next_page(accumulated: accumulated, current_page: results)
      end
    end

    def next_page(accumulated:, current_page:)
      return nil unless more_pages?(accumulated, current_page)

      self.class.new(model: model, api: api, constraints: constraints.next_page)
    end

    def more_pages?(accumulated, current_page)
      return false if current_page.empty?
      return false if constraints.limit && accumulated >= constraints.limit
      return false if constraints.per_page && current_page.length < constraints.per_page

      true
    end

    # Retrieves a record. Nylas doesn't support where filters on GET so this will not take into
    # consideration other query constraints, such as where clauses.
    def find(id)
      constraints.accept == "application/json" ? find_model(id) : find_raw(id)
    end

    def find_raw(id)
      api.execute(**to_be_executed.merge(path: "#{resources_path}/#{id}")).to_s
    end

    def resources_path
      model.resources_path(api: api)
    end

    def find_model(id)
      instance = model.from_hash({ id: id }, api: api)
      instance.reload
      instance
    end

    # @return [Hash] Specification for request to be passed to {API#execute}
    def to_be_executed
      { method: :get, path: resources_path, query: constraints.to_query,
        headers: constraints.to_headers }
    end

    # Retrieves the data from the API for the particular constraints
    # @return [Hash,Array]
    def execute
      api.execute(**to_be_executed)
    end
  end
end
