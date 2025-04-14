/*******************************************************************************

    Index-based registry

    This implementation superseeds the legacy registry and queries Github
    directly for a well-known index that is cloned locally and always
    accessible. This ensures that our only dependency for fetching packages
    is Github, reducing the risk of downtime. This supplier also soft-fail when
    the network is not available, ensuring that users even offline can perform
    search if they have a checked out (but possibly outdated) index.

*******************************************************************************/

module dub.packagesuppliers.index;

import dub.dependency;
import dub.internal.configy.Read;
import dub.internal.utils;
import dub.internal.vibecompat.inet.url;
import dub.packagesuppliers.packagesupplier;
import dub.recipe.packagerecipe;

import std.algorithm;
import std.array : array;
import std.exception;
static import std.file;
import std.format;
import std.range : retro;
import std.string;
import std.typecons;

/// Ditto
public class IndexPackageSupplier : PackageSupplier {
    /// The path at which the index resides
    protected string path;
    /// Whether git clone or git pull has been called during this program's
    /// lifetime (it is called at most once).
    protected bool initialized;

    /***************************************************************************

        Instantiate a new `IndexPackageSupplier`

        Params:
          path = The root path where the index is (to be) checked out

    ***************************************************************************/

    public this (string path) @safe pure nothrow @nogc {
        this.path = path;
    }

    ///
	public override @property string description () {
        return "index-based registry (" ~ this.path ~ ")";
    }

    ///
	public override Version[] getVersions (in PackageName name) {
        this.ensureInitialized();
        const pkg = this.loadPackageDesc(name);
        return pkg.versions.map!(vers => Version(vers.version_)).array;
    }

    /**
     * Fetch a package directly from the provider.
     *
     * See_Also:
     *   - https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#download-a-repository-archive-zip
     */
	public override ubyte[] fetchPackage (in PackageName name,
        in VersionRange dep, bool pre_release) {
        import dub.internal.git;

        this.ensureInitialized();
        const pkgdesc = this.loadPackageDesc(name);
        auto vers = pkgdesc.bestMatch(dep);
        enforce(!vers.isNull(), "No package found matching dep");
        switch (pkgdesc.repository.kind) {
            case "github":
                const url = "https://api.github.com/repos/%s/%s/zipball/%s".format(
                    pkgdesc.repository.owner, pkgdesc.repository.project, vers.get());
                return retryDownload(URL(url));
            default:
                throw new Exception("Unhandled repository kind");
        }
    }

    ///
	public override Json fetchPackageRecipe(in PackageName name,
        in VersionRange dep, bool pre_release) {
        this.ensureInitialized();
        const pkgdesc = this.loadPackageDesc(name);
        const vers = pkgdesc.bestMatch(dep);
        enforce(!vers.isNull(),
            "Cannot fetch version '%s' of package '%s': No such version exists"
            .format(dep, name));
        // Note: Only 'version' is used from the return of 'fetchPackageRecipe'
        Json res;
        res["version"] = vers.get().name;
        return res;
    }

    /**
     * Search all packages matching the query
     *
     * Note that it is an expensive operation as it iterates over the whole
     * index locally. This is currently only called from `dub search` and
     * is unlikely to be called from any long-running processed so we're
     * not concerned about memory usage / speed (a couple seconds is fine).
     */
	public override SearchResult[] searchPackages (string query) {
        static SearchResult addPackage (in PackageIndex idx) {
            auto maxVers = idx.bestMatch(VersionRange.Any);
            return SearchResult(idx.name, idx.description, maxVers.get().version_);
        }

        typeof(return) results;
        this.ensureInitialized();
        const origSound = query.soundexer();
        foreach (entry; std.file.dirEntries(this.path, std.file.SpanMode.depth)) {
            if (!entry.isFile()) continue;
            try {
                const desc = parseConfigString!PackageIndex(
                        std.file.readText(entry.name), entry.name);
                if (!desc.versions.length) continue;
                // Some heuristics
                if (desc.name.canFind(query) || desc.description.canFind(query))
                    results ~= addPackage(desc);
                else if (desc.name.soundexer == origSound)
                    results ~= addPackage(desc);
            } catch (ConfigException exc) {
                import std.stdio;
                writefln("Error? %S", exc);
                continue;
            }
        }
        return results;
    }

    /**
     * Called by every method to ensure the index is available and up to date
     *
     * This method will hard fail if no index is available and the index cannot
     * be cloned, and soft-fail when the index cannot be updated.
     * It ensures that the index is updated at most once per program invocation.
     *
     * Returns:
     *   Whether this was the first call to `ensureInitialized`.
     *
     * Throws:
     *   If cloning the index failed.
     */
    protected bool ensureInitialized () {
        import dub.internal.git;

        if (this.initialized) return false;
        scope (exit) this.initialized = true;

        if (!std.file.exists(this.path))
            enforce(
                cloneRepository("https://github.com/skoppe/dub-packages-index.git",
                    "master", this.path),
                "Cloning the repository failed - ensure you have a working internet " ~
                "connection or use `--skip-registry`");
        else {
            updateRepository(this.path, "master");
        }
        return true;
    }

    /**
     * Loads a package description from the index.
     *
     * This attempts to load a package description from the index.
     * If no such description exists, an `Exception` is thrown.
     *
     * Params:
     *   name = The name of the package to load a description for.
     */
    protected PackageIndex loadPackageDesc (in PackageName name) {
        import std.path;
        import std.range;

        const main = name.main.toString();
        string file;
        if (main.length < 2)
            file = this.path.buildPath(main, main, main);
        else {
            const char[2] end = [ main[$-1], main[$-2] ];
            file = this.path.buildPath(main[0 .. 2], end, main);
        }
        enforce(std.file.exists(file), "No such package: %s".format(name));
        return parseConfigString!PackageIndex(std.file.readText(file), file);
    }
}

private struct PackageIndex {
    string id;
    string name;
    string owner;
    string commitID;
    string dateAdded;
    string description;
    string documentationURL;
    @Optional string[] categories;
    RepositoryDesc repository;
    VersionDesc[] versions;
}

private struct RepositoryDesc {
    string kind;
    string owner;
    string project;
}

private struct VersionDesc {
    public string name;
    public @Optional string commitID;
	public @Optional @Key("name") ConfigurationInfo[] configurations;
	public @Optional RecipeDependency[string] dependencies;
    public @Name("version") string version_;
    public @Optional SubPackageDesc[] subPackages;
}

private struct SubPackageDesc {
    public string name;
	public @Optional @Key("name") ConfigurationInfo[] configurations;
    public @Optional RecipeDependency[string] dependencies;
}

/**
 * From a package description, find the version that best matches the range
 *
 * Params:
 *   pkg = The package description to look at
 *   dep = The expected version range to match
 *
 * Returns:
 *   The highest version matching `dep`, or `nullable()` if none does.
 */
private Nullable!(const(VersionDesc)) bestMatch (in PackageIndex pkg, in VersionRange dep) {
    size_t idx = pkg.versions.length;
    foreach (eidx, ref vers; pkg.versions) {
        // Is it a match ?
        if (dep.matches(Version(vers.version_))) {
            if (idx < pkg.versions.length) {
                // Is it a better match ?
                if (pkg.versions[idx].version_ < vers.version_)
                    eidx = idx;
            } else {
                // We don't have a match yet
                eidx = idx;
            }
        }
    }
    return idx < pkg.versions.length ? nullable(pkg.versions[idx]) : typeof(return).init;
}
