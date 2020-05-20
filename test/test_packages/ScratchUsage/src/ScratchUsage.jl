module ScratchUsage
using Pkg, Pkg.Spaces

function get_version(uuid)
    ctx = Pkg.Types.Context()

    # We know that we will always be listed in the manifest during tests.
    uuid, entry = first(filter(((u, e),) -> u == uuid, ctx.env.manifest))
    return entry.version
end

const my_uuid = Base.PkgId(@__MODULE__).uuid
const my_version = get_version(my_uuid)

# This function will create a bevy of spaces here
function touch_spaces()
    # Create an explicitly version-specific space
    private_space = get_space!(
        string(my_version.major, ".", my_version.minor, ".", my_version.patch);
        pkg_uuid=my_uuid,
    )
    touch(joinpath(private_space, string("ScratchUsage-", my_version)))

    # Create a space shared between all instances of the same major version,
    # using the `@get_space!` macro which automatically looks up the UUID
    major_space = @get_space!(string(my_version.major))
    touch(joinpath(major_space, string("ScratchUsage-", my_version)))

    # Create a global space that is not locked to this package at all
    global_space = get_space!("GlobalSpace")
    touch(joinpath(global_space, string("ScratchUsage-", my_version)))
end

end # module ScratchUsage