--[[

Implements an index that can be used to efficiently search for items that
share similar characteristics.

This implementation is based on MinHash (which is used quickly identify
similar items and estimate the Jaccard similarity of their characteristic
sets) but this implementation extends the typical design to add the ability
to record items by an arbitrary key. This allows querying for similar
groups that contain many different characteristic sets.

This is modeled as two data structures:

- A bucket frequency hash, which maintains a count of what buckets
    have been recorded -- and how often -- in a ``(band, key)`` pair. This
    data can be used to identify what buckets a key is a member of, and also
    used to identify the degree of bucket similarity when comparing with data
    associated with another key.
- A bucket membership set, which maintains a record of what keys have been
    record in a ``(band, bucket)`` pair. This data can be used to identify
    what other keys may be similar to the lookup key (but not the degree of
    similarity.)

]]--


-- Try and enable script effects replication if we're using Redis 3.2 or
-- greater. This is wrapped in `pcall` so that we can continue to support older
-- Redis versions while using this feature if it's available.
if not pcall(redis.replicate_commands) then
    redis.log(redis.LOG_DEBUG, 'Could not enable script effects replication.')
end


-- Utilities

local function identity(...)
    return ...
end

local function default_table(default)
    return setmetatable({}, {
        __index = function (table, key)
            local value = default(key)
            table[key] = value
            return value
        end,
    })
end

local function map(func, iterator, state, control)
    return function ()
        local result = {iterator(state, control)}
        control = result[1]
        while control ~= nil do
            result = {iterator(state, control)}
            control = result[1]
            return func(unpack(result))
        end
    end
end

local function filter(predicate, iterator, state, control)
    return function ()
        local result = {iterator(state, control)}
        control = result[1]
        while control ~= nil do
            if predicate(unpack(result)) then
                return unpack(result)
            end
            result = {iterator(state, control)}
            control = result[1]
        end
    end
end

local function redis_hash_response_iterator(response)
    local i = 1
    return function ()
        local key, value = response[i], response[i + 1]
        i = i + 2
        return key, value
    end
end


-- Distance Calculation

local function get_manhattan_distance(target, other)
    local keys = {}
    for k, _ in pairs(target) do
        keys[k] = true
    end

    for k, _ in pairs(other) do
        keys[k] = true
    end

    local total = 0
    for k, _ in pairs(keys) do
        total = total + math.abs((target[k] or 0) - (other[k] or 0))
    end

    return total
end

local function scale_to_total(values)
    local result = {}
    local total = 0
    for key, value in pairs(values) do
        total = total + value
    end
    for key, value in pairs(values) do
        -- NOTE: This doesn't have to be guarded against division by zero
        -- (assuming all value are positive and nonzero) since if total is 0,
        -- there are no items.
        result[key] = value / total
    end
    return result
end


-- Frequencies

local Frequencies = {}

function Frequencies:new(data)
    return setmetatable(data, {__index = self})
end

function Frequencies:empty()
    return next(self[1], nil) == nil
end


-- Time Series Set

local TimeSeriesSet = {}

function TimeSeriesSet:new(window, retention, key_function)
    return setmetatable({
        window = window,
        retention = retention,
        key_function = key_function,
    }, {__index = self})
end

function TimeSeriesSet:insert(timestamp, ...)
    local index = math.floor(timestamp / self.window)
    local key = self.key_function(index)
    local result = redis.call('SADD', key, ...)
    if result > 0 then
        -- The expiration only needs updating if we've actually added anything.
        redis.call('EXPIREAT', key, (index + 1 + self.retention) * self.window)
    end
    return result
end

function TimeSeriesSet:members(timestamp)
    local results = {}
    local current = math.floor(timestamp / self.window)
    for index = current - self.retention, current do
        local members = redis.call('SMEMBERS', self.key_function(index))
        for i = 1, #members do
            local k = members[i]
            results[k] = (results[k] or 0) + 1
        end
    end
    return results
end


-- Configuration

local Configuration = {}

function Configuration:new(scope, bands, window, retention, timestamp)
    return setmetatable({
        scope = scope,
        bands = bands,
        window = window,
        retention = retention,
        timestamp = timestamp,
        frequency_key_format = '>BH',
    }, {__index = self})
end

function Configuration:pack_frequency_key(band, bucket)
    return struct.pack(self.frequency_key_format, band, bucket)
end

function Configuration:unpack_frequency_key(key)
    return struct.unpack(self.frequency_key_format, key)
end

function Configuration:get_candidate_index(index, band, bucket)
    local key_prefix = table.concat({
        self.scope,
        index,
        self:pack_frequency_key(band, bucket),
        '',
    }, ':')
    return TimeSeriesSet:new(
        self.window,
        self.retention,
        function (i)
            return key_prefix .. i
        end
    )
end

function Configuration:get_candidates(index, frequencies)
    local candidates = default_table(
        function ()
            local value = {}
            for band = 1, self.bands do
                value[band] = 0
            end
            return value
        end
    )

    for band = 1, self.bands do
        for bucket, _ in pairs(frequencies[band]) do
            for candidate, _ in pairs(self:get_candidate_index(index, band, bucket):members(self.timestamp)) do
                candidates[candidate][band] = candidates[candidate][band] + 1
            end
        end
    end

    local results = {}
    for candidate, bands in pairs(candidates) do
        local collisions = 0
        for band = 1, self.bands do
            if bands[band] > 0 then
                collisions = collisions + 1
            end
        end
        results[candidate] = collisions
    end
    return results
end

function Configuration:get_frequencies(index, item)
    local frequencies = {}
    for band = 1, self.bands do
        frequencies[band] = {}
    end

    local response = redis.call('HGETALL', string.format('%s:f:%s:%s', self.scope, index, item))
    for key, count in redis_hash_response_iterator(response) do
        local band, bucket = self:unpack_frequency_key(key)
        frequencies[band][bucket] = tonumber(count)
    end

    return Frequencies:new(frequencies)
end

function Configuration:set_frequencies(index, item, frequencies)
    local key = string.format('%s:f:%s:%s', self.scope, index, item)
    for band = 1, self.bands do
        for bucket, count in pairs(frequencies[band]) do
            redis.call('HINCRBY', key, self:pack_frequency_key(band, bucket), count)
        end
    end
    redis.call('EXPIREAT', key, self.timestamp + (self.retention * self.window))
end

function Configuration:calculate_similarity(target_frequencies, other_frequencies)
    local sum = 0
    for band = 1, self.bands do
        local distance = get_manhattan_distance(
            scale_to_total(target_frequencies[band]),
            scale_to_total(other_frequencies[band])
        )
        sum = sum + (1 - distance / 2)
    end
    return sum / self.bands
end


-- Argument Parsing

local function argument_parser(callback)
    if callback == nil then
        callback = identity
    end

    return function (cursor, arguments)
        return cursor + 1, callback(arguments[cursor])
    end
end

local function flag_argument_parser(flags)
    return function (cursor, arguments)
        local result = {}
        while flags[arguments[cursor]] do
            result[arguments[cursor]] = true
            cursor = cursor + 1
        end
        return cursor, result
    end
end

local function repeated_argument_parser(argument_parser, quantity_parser, callback)
    if quantity_parser == nil then
        quantity_parser = function (cursor, arguments)
            return cursor + 1, tonumber(arguments[cursor])
        end
    end

    if callback == nil then
        callback = identity
    end

    return function (cursor, arguments)
        local results = {}
        local cursor, count = quantity_parser(cursor, arguments)
        for i = 1, count do
            cursor, results[i] = argument_parser(cursor, arguments)
        end
        return cursor, callback(results)
    end
end

local function object_argument_parser(schema, callback)
    if callback == nil then
        callback = identity
    end

    return function (cursor, arguments)
        local result = {}
        for i, specification in ipairs(schema) do
            local key, parser = unpack(specification)
            cursor, result[key] = parser(cursor, arguments)
        end
        return cursor, callback(result)
    end
end

local function variadic_argument_parser(argument_parser)
    return function (cursor, arguments)
        local results = {}
        local i = 1
        while arguments[cursor] ~= nil do
            cursor, results[i] = argument_parser(cursor, arguments)
            i = i + 1
        end
        return cursor, results
    end
end

local function multiple_argument_parser(...)
    local parsers = {...}
    return function (cursor, arguments)
        local results = {}
        for i, parser in ipairs(parsers) do
            cursor, results[i] = parser(cursor, arguments)
        end
        return cursor, unpack(results)
    end
end

local function frequencies_argument_parser(bands)
    return repeated_argument_parser(
        function (cursor, arguments)
            local buckets = {}
            return repeated_argument_parser(
                function (cursor, arguments)
                    buckets[tonumber(arguments[cursor])] = tonumber(arguments[cursor + 1])
                    return cursor + 2
                end
            )(cursor, arguments), buckets
        end,
        function (cursor, arguments)
            return cursor, bands
        end,
        function (frequencies)
            return Frequencies:new(frequencies)
        end
    )
end


-- Command Execution

local commands = {
    RECORD = function (configuration, cursor, arguments)
        local cursor, requests = variadic_argument_parser(
            object_argument_parser({
                {"key", argument_parser()},
                {"index", argument_parser()},
                {"frequencies", frequencies_argument_parser(configuration.bands)},
            })
        )(cursor, arguments)

        for i, request in ipairs(requests) do
            configuration:set_frequencies(request.index, request.key, request.frequencies)
            for band = 1, configuration.bands do
                for bucket, _ in pairs(request.frequencies[band]) do
                    configuration:get_candidate_index(request.index, band, bucket):insert(configuration.timestamp, request.key)
                end
            end
        end
    end,
    CLASSIFY = function (configuration, cursor, arguments)
        local cursor, flags, requests = multiple_argument_parser(
            flag_argument_parser({
                STRICT = true
            }),
            variadic_argument_parser(
                object_argument_parser({
                    {"index", argument_parser()},
                    {"threshold", argument_parser(tonumber)},
                    {"frequencies", frequencies_argument_parser(configuration.bands)},
                })
            )
        )(cursor, arguments)

        local candidates = default_table(
            function ()
                return {}
            end
        )

        for i, request in ipairs(requests) do
            for candidate, collisions in pairs(configuration:get_candidates(request.index, request.frequencies)) do
                candidates[candidate][request.index] = collisions
            end
        end

        local predicate
        if flags.STRICT then
            -- STRICT mode requires that all thresholds are met for the
            -- candidate for all features that contain data on the target *and*
            -- that the candidate not contain data for any features that are
            -- not also present on the target.
            predicate = function (candidate, indices)
                -- TODO: This filter should only be applied if the frequencies
                -- actually contain any entries. (If the target doesn't have
                -- any records for the feature, of course there won't be any
                -- collisions.)
                for i, request in ipairs(requests) do
                    if (indices[request.index] or 0) < request.threshold then
                        return false
                    end
                end
                return true
            end
        else
            -- Normal (non-STRICT) mode just requires that a single feature be
            -- over the threshold.
            predicate = function (candidate, indices)
                for i, request in ipairs(requests) do
                    if (indices[request.index] or 0) >= request.threshold then
                        return true
                    end
                end
                return false
            end
        end

        local score
        if flags.STRICT then
            score = function (candidate, indices)
                local result = {}
                for i, request in ipairs(requests) do
                    local candidate_frequencies = configuration:get_frequencies(request.index, candidate)
                    if (request.frequencies:empty() and candidate_frequencies:empty()) or
                        (not request.frequencies:empty() and not candidate_frequencies:empty()) then
                        result[i] = configuration:calculate_similarity(
                            request.frequencies,
                            candidate_frequencies
                        )
                    else
                        return candidate, false, {}
                    end
                end
                return candidate, true, result
            end
        else
            score = function (candidate, indices)
                local result = {}
                for i, request in ipairs(requests) do
                    if request.frequencies:empty() then
                        result[i] = -1
                    else
                        local candidate_frequencies = configuration:get_frequencies(request.index, candidate)
                        if candidate_frequencies:empty() then
                            result[i] = -1
                        else
                            result[i] = configuration:calculate_similarity(
                                request.frequencies,
                                configuration:get_frequencies(request.index, candidate)
                            )
                        end
                    end
                end
                return candidate, true, result
            end
        end

        local results = {}
        for candidate, include, scores in map(score, filter(predicate, pairs(candidates))) do
            if include then
                results[#results + 1] = {
                    candidate,
                    scores,
                }
            end
        end

        -- TODO: Rewrite response to have strings instead of floats to avoid truncation

        return results
    end,
}

local cursor, configuration = object_argument_parser({
    {"scope", argument_parser()},
    {"bands", argument_parser(tonumber)},
    {"window", argument_parser(tonumber)},
    {"retention", argument_parser(tonumber)},
    {"timestamp", argument_parser(tonumber)},
}, function (obj)
    return Configuration:new(
        obj.scope,
        obj.bands,
        obj.window,
        obj.retention,
        obj.timestamp
    )
end)(1, ARGV)

local command
cursor, command = argument_parser(
    function (argument)
        return commands[argument]
    end
)(cursor, ARGV)

return command(configuration, cursor, ARGV)
