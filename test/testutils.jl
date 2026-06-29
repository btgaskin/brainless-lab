module BrainlessLabTestUtils

function scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Float64(value) : Float64(only(value))
end

function int_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Int(value) : Int(only(value))
end

end
