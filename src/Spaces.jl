module Spaces
import ...Pkg
using ...Pkg.TOML, Dates

export with_spaces_directory, spaces_dir, get_space!, delete_space!, clear_spaces!, @get_space!

const spaces_dir_OVERRIDE = Ref{Union{String,Nothing}}(nothing)
"""
    with_spaces_directory(f::Function, spaces_dir::String)

Helper function to allow temporarily changing the scratchspace directory.  When this is set,
no other directory will be searched for spaces, and new spaces will be created within
this directory.  Similarly, removing a space will only effect the given space directory.
"""
function with_spaces_directory(f::Function, spaces_dir::String)
    try
        spaces_dir_OVERRIDE[] = spaces_dir
        f()
    finally
        spaces_dir_OVERRIDE[] = nothing
    end
end

"""
    spaces_dir(args...)

Returns a path within the current depot's `scratchspaces` directory.  This location can be
overridden via `with_spaces_directory()`.
"""
function spaces_dir(args...)
    if spaces_dir_OVERRIDE[] === nothing
        return abspath(Pkg.depots1(), "scratchspaces", args...)
    else
        # If we've been given an override, use _only_ that directory.
        return abspath(spaces_dir_OVERRIDE[], args...)
    end
end

"""
    space_path(key, pkg_uuid)

Common utility function to return the path of a space, keyed by the given parameters.
Users should use `get_space!()` for most user-facing usage.
"""
function space_path(key::AbstractString, pkg_uuid::Union{Base.UUID,Nothing} = nothing)
    # If we were not given a UUID, we use the "global space" UUID:
    if pkg_uuid === nothing
        pkg_uuid = Base.UUID(UInt128(0))
    end

    return spaces_dir(string(pkg_uuid), key)
end

# Session-based space access time tracker
space_access_timers = Dict{String,Float64}()
"""
    track_space_access(pkg_uuid, space_path)

We need to keep track of who is using which spaces, so we know when it is advisable to
remove them during a GC.  We do this by attributing accesses of spaces to `Manifest.toml`
files in much the same way that package versions themselves are logged upon install, only
instead of having the manifest information implicitly available, we must rescue it out
from the currently-active Pkg Env.  If we cannot do that, it is because someone is doing
something weird like opening a space for a Pkg UUID that is not loadable, which we will
simply not track; that space will be reaped after the appropriate time in an orphanage.

If `pkg_uuid` is explicitly set to `nothing`, this space is treated as belonging to the
default global manifest next to the global project at `Base.load_path_expand("@v#.#")`.

While package and artifact access tracking can be done at `add()`/`instantiate()` time,
we must do it at access time for spaces, as we have no declarative list of spaces that
a package may or may not access throughout its lifetime.  To avoid building up a
ludicrously large number of accesses through programs that e.g. call `get_space!()` in a
loop, we only write out usage information for each space once per day at most.
"""
function track_space_access(pkg_uuid::Union{Base.UUID,Nothing}, space_path::AbstractString)
    # Don't write this out more than once per day within the same Julia session.
    curr_time = time()
    if get(space_access_timers, space_path, 0.0) >= curr_time - 60*60*24
        return
    end

    function find_project_file(pkg_uuid)
        # The simplest case (`pkg_uuid` == `nothing`) simply attributes the space to
        # the global depot environment, which will never cause the space to be GC'ed
        # because it has been removed, as long as the depot itself is intact.
        if pkg_uuid === nothing
            return Base.load_path_expand("@v#.#")
        end

        # The slightly more complicated case inspects the currently-loaded Pkg env
        # to find the project file that we should tie our lifetime to.  If we can't
        # find it, we'll return `nothing` and skip tracking access.
        ctx = Pkg.Types.Context()

        # Check to see if the UUID is the overall project itself:
        if ctx.env.pkg !== nothing && ctx.env.pkg.uuid == pkg_uuid
            return ctx.env.project_file
        end

        # Finally, check to see if the package is loadable from the current environment
        if haskey(ctx.env.manifest, pkg_uuid)
            pkg_entry = ctx.env.manifest[pkg_uuid]
            pkg_path = Pkg.Operations.source_path(
                ctx,
                Pkg.Types.PackageSpec(
                    name=pkg_entry.name,
                    uuid=pkg_uuid,
                    tree_hash=pkg_entry.tree_hash,
                    path=pkg_entry.path,
                )
            )
            project_path = joinpath(pkg_path, "Project.toml")
            if isfile(project_path)
                return project_path
            end
        end

        # If we couldn't find anything to attribute the space to, return `nothing`.
        return nothing
    end

    # We must decide which manifest to attribute this space to.
    project_file = abspath(find_project_file(pkg_uuid))

    # If we couldn't find one, skip out.
    if project_file === nothing
        return
    end

    entry = Dict(
        "time" => now(),
        "parent_projects" => [project_file],
    )
    Pkg.Types.write_env_usage(abspath(space_path), "scratch_usage.toml", entry)

    # Record that we did, in fact, write out the space access time
    space_access_timers[space_path] = curr_time
end


const VersionConstraint = Union{VersionNumber,AbstractString,Nothing}

"""
    get_space!(key::AbstractString; pkg_uuid = nothing)

Returns the path to (or creates) a space.

If `pkg_uuid` is defined, the scratchspace is namespaced with that package's UUID, so
that it will not conflict with any other space with the same name but a different parent
package UUID.  The space's lifecycle is tied to that parent package, allowing the space
to be eagerly removed if all versions of the package that used it have been removed.

If `pkg_uuid` is not defined, a global scratchspace that is not explicitly lifecycled
will be created.

In the current implementation, spaces are removed if they have not been accessed for a
predetermined amount of time or sooner if the package they are lifecycled to has been
garbage collected.  See `Pkg.gc()` and `track_space_access()` for more details.

!!! note
    Package scratchspaces should never be treated as persistent storage; they are allowed
    to disappear at any time, and all content within them must be nonessential or easily
    recreatable.  All lifecycle guarantees set a maximum lifetime for the space, never
    a minimum.
"""
function get_space!(key::AbstractString; pkg_uuid::Union{Base.UUID,Nothing} = nothing)
    # Calculate the path and create the containing folder
    path = space_path(key, pkg_uuid)
    mkpath(path)

    # We need to keep track of who is using which spaces, so we track usage in a log
    track_space_access(pkg_uuid, path)
    return path
end

"""
    delete_space!(;key, pkg_uuid)

Explicitly deletes a space created through `get_space!()`.
"""
function delete_space!(key::AbstractString; pkg_uuid::Union{Base.UUID,Nothing} = nothing)
    path = space_path(key, pkg_uuid)
    rm(path; force=true, recursive=true)
    delete!(space_access_timers, path)
    return nothing
end

"""
    clear_spaces!()

Delete all spaces in the current depot.
"""
function clear_spaces!()
    rm(spaces_dir(); force=true, recursive=true)
    empty!(space_access_timers)
    return nothing
end

"""
    @get_space!(key)

Convenience macro that gets/creates a scratchspace lifecycled to the package the calling
module belongs to with the given key.  If the calling module does not belong to a
package, (e.g. it is `Main`, `Base`, an anonymous module, etc...) the UUID will be taken
to be `nothing`, creating a global scratchspace.
"""
macro get_space!(key)
    # Note that if someone uses this in the REPL, it
    uuid = Base.PkgId(__module__).uuid
    return quote
        get_space!($(esc(key)); pkg_uuid=$(esc(uuid)))
    end
end

end # module Spaces