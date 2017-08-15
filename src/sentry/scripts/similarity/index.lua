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
--[[
if not pcall(redis.replicate_commands) then
    redis.log(redis.LOG_DEBUG, 'Could not enable script effects replication.')
end
]]--

--[[
local reduce = function (callback, initializer, iterator, state, ...)
    local v = initializer
    local i = {iterator(state, ...)}
    while i[1] ~= nil do
        v = callback(v, unpack(i))
        i = {iterator(state, i[1])}
    end
    return v
end
]]--

local function redis_hash_response_iterator(response)
    local i = 1
    return function ()
        local key, value = response[i], response[i + 1]
        i = i + 2
        return key, value
    end
end

function table.slice(t, start, stop)
    if stop == nil then
        stop = #t
    end

    local result = {}
    for i = start, stop do
        result[i - start + 1] = t[i]
    end
    return result
end

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

local function parse_configuration(arguments)
    local configuration = {
        scope = arguments[1],
        bands = tonumber(arguments[2]),
        window = tonumber(arguments[3]),
        retention = tonumber(arguments[4]),
        timestamp = tonumber(arguments[5]),
        byte_order = '>',  -- network byte order
        band_format = 'B',
        bucket_format = 'H',
    }

    local TimeSeriesSet = {}

    function TimeSeriesSet:new(key_function)
        return setmetatable({
            key_function = key_function,
        }, {
            __index = self,
        })
    end

    -- TODO: Some of this time series stuff should probably be extracted.

    function TimeSeriesSet:insert(...)
        local index = math.floor(configuration.timestamp / configuration.window)
        local key = self.key_function(index)
        local result = redis.call('SADD', key, ...)
        if result > 0 then
            -- The expiration only needs updating if we've actually added anything.
            redis.call('EXPIREAT', key, (index + 1 + configuration.retention) * configuration.window)
        end
        return result
    end

    function TimeSeriesSet:members()
        local results = {}
        local current = math.floor(configuration.timestamp / configuration.window)
        for index = current - configuration.retention, current do
            local members = redis.call('SMEMBERS', self.key_function(index))
            for i = 1, #members do
                local k = members[i]
                results[k] = (results[k] or 0) + 1
            end
        end
        return results
    end

    configuration.frequency_key_format = string.format(
        '%s%s%s',
        configuration.byte_order,
        configuration.band_format,
        configuration.bucket_format
    )

    function configuration:pack_frequency_key(band, bucket)
        return struct.pack(self.frequency_key_format, band, bucket)
    end

    function configuration:unpack_frequency_key(key)
        return struct.unpack(self.frequency_key_format, key)
    end

    function configuration:get_candidate_index(index, band, bucket)
        return TimeSeriesSet:new(
            function (i)
                return string.format('%s:c:%s:', self.scope, index) .. self:pack_frequency_key(bucket, band) .. string.format(':%s', i)
            end
        )
    end

    function configuration:get_frequencies(index, item)
        local frequencies = {}
        for band = 1, self.bands do
            frequencies[band] = {}
        end

        local response = redis.call('HGETALL', string.format('%s:f:%s:%s', self.scope, index, item))
        for key, count in redis_hash_response_iterator(response) do
            local band, bucket = self:unpack_frequency_key(key)
            frequencies[band][bucket] = tonumber(count)
        end

        return frequencies
    end

    function configuration:set_frequencies(index, item, frequencies)
        local arguments = {}
        local key = string.format('%s:f:%s:%s', self.scope, index, item)
        for band = 1, self.bands do
            for bucket, count in pairs(frequencies[band]) do
                redis.call('HINCRBY', key, self:pack_frequency_key(band, bucket), count)
            end
        end
        redis.call('EXPIREAT', key, self.timestamp + (self.retention * self.window))
    end

    function configuration:get_candidates(index, frequencies)
        local candidates = setmetatable({}, {
            __index = function (t, k)
                t[k] = {}
                return t[k]
            end,
        })

        for band = 1, self.bands do
            for bucket, _ in pairs(frequencies[band]) do
                for candidate, _ in pairs(self:get_candidate_index(index, band, bucket):members()) do
                    local hits = candidates[candidate]
                    hits[band] = (hits[band] or 0) + 1
                end
            end
        end

        local results = {}
        for candidate, bands in pairs(candidates) do
            local collisions = 0
            for band, buckets in pairs(bands) do
                collisions = collisions + 1
            end
            results[candidate] = collisions
        end
        return results
    end

    function configuration:calculate_similarity(target, other)
        local total = 0
        for band = 1, self.bands do
            local distance = get_manhattan_distance(
                scale_to_total(target[band]),
                scale_to_total(other[band])
            )
            total = total + (1 - distance / 2)
        end
        return total / self.bands
    end

    return configuration, arguments[6], table.slice(arguments, 7)
end

local parse_repeated_arguments = function (parser, arguments, cursor)
    local count = tonumber(arguments[cursor])
    cursor = cursor + 1

    local results = {}
    for i = 1, count do
        cursor, results[i] = parser(arguments, cursor)
    end

    return cursor, results
end

local parse_frequencies = function (configuration, arguments, cursor)
    local frequencies = {}
    for i = 1, configuration.bands do
        local buckets = {}
        cursor = parse_repeated_arguments(
            function (arguments, cursor)
                buckets[tonumber(arguments[cursor])] = tonumber(arguments[cursor + 1])
                return cursor + 2
            end,
            arguments,
            cursor
        )
        frequencies[i] = buckets
    end
    return cursor, frequencies
end

local commands = {
    RECORD = function (configuration, arguments)
        local requests = {}
        local cursor = 1
        while arguments[cursor] ~= nil do
            local request = {
                key = arguments[cursor],
                index = arguments[cursor + 1],
            }
            cursor, request.frequencies = parse_frequencies(configuration, arguments, cursor + 2)
            requests[#requests + 1] = request
        end

        for i, request in ipairs(requests) do
            configuration:set_frequencies(request.index, request.key, request.frequencies)
            for band = 1, configuration.bands do
                for bucket, _ in pairs(request.frequencies[band]) do
                    configuration:get_candidate_index(request.index, band, bucket):insert(request.key)
                end
            end
        end
    end,
    COMPARE = function (configuration, arguments)
        error('not implemented')
    end,
    CLASSIFY = function (configuration, arguments)
        local requests = {}
        local cursor = 1
        while arguments[cursor] ~= nil do
            local request = {
                index = arguments[cursor],
                threshold = tonumber(arguments[cursor]),
            }
            cursor, request.frequencies = parse_frequencies(configuration, arguments, cursor + 2)
            requests[#requests + 1] = request
        end

        local candidates = setmetatable({}, {
            __index = function (t, k)
                t[k] = {}
                return t[k]
            end,
        })

        for i, request in ipairs(requests) do
            for candidate, collisions in pairs(configuration:get_candidates(request.index, request.frequencies)) do
                candidates[candidate][request.index] = collisions
            end
        end

        local results = {}
        for candidate, _ in pairs(candidates) do
            local result = {}
            for i, request in ipairs(requests) do
                result[i] = string.format(
                    '%f',
                    configuration:calculate_similarity(
                        request.frequencies,
                        configuration:get_frequencies(request.index, candidate)
                    )
                )
            end
            results[candidate] = result
        end

        return results
    end,
    MERGE = function (configuration, arguments)
        error('not implemented')
    end,
    DELETE = function (configuration, arguments)
        error('not implemented')
    end,
}

local configuration, command, arguments = parse_configuration(ARGV)
return commands[command](configuration, arguments)
