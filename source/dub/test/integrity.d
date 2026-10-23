/** Tests for archive integrity pins and their persistence across cache reuse. */
module dub.test.integrity;

version (unittest):

import dub.test.base;
import dub.recipe.selection;
import dub.packagemanager : PackageManager, PlacementLocation;
import std.exception : assertThrown, collectException;

private enum SelectionsPath = TestDub.ProjectPath ~ "dub.selections.json";

private TestDub newProject(string dependency = "~>1.0")
{
    return new TestDub((scope Filesystem fs) {
        fs.writeFile(TestDub.ProjectPath ~ "dub.json",
            `{"name":"a","dependencies":{"b":"` ~ dependency ~ `"}}`);
    });
}

private void addPackage(MockPackageSupplier registry, string ver = "1.0.0", string contents = "original")
{
    registry.add(Version(ver), (scope Filesystem fs) {
        fs.writeFile(NativePath("dub.json"), `{"name":"b"}`);
        fs.writeFile(NativePath("source.d"), contents);
    });
}

private void writePin(TestDub dub, string ver, IntegrityTag tag)
{
    dub.fs.writeFile(SelectionsPath, `{"fileVersion":1,"versions":{"b":{"version":"` ~
        ver ~ `","integrity":"` ~ tag.toString() ~ `"}}}`);
}

private class RetryingSupplier : MockPackageSupplier
{
    size_t requests;
    bool alwaysCorrupt;
    this() { super("test registry"); }

    override ubyte[] fetchPackage(in PackageName name, in VersionRange range, bool preRelease)
    {
        // Fetch must pin the version chosen from the recipe, even if the user
        // originally requested a version range.
        assert(range.isExactVersion);
        auto data = super.fetchPackage(name, range, preRelease);
        if (++requests == 1 || alwaysCorrupt)
        {
            // Break a local file header while retaining the ZIP directory,
            // so extraction fails after the destination has been created.
            data = data.dup;
            data[0] = 0;
        }
        return data;
    }
}

// Fresh downloads write pins; subsequent processes can recover them without a registry.
unittest
{
    scope dub = newProject();
    addPackage(dub.getRegistry());
    dub.loadPackage();
    dub.upgrade(UpgradeOptions.select);
    const tag = dub.project.selections.getIntegrityTag(PackageName("b"));
    assert(tag.algorithm == "sha512");
    const lockfile = dub.fs.readText(SelectionsPath);
    assert(lockfile.canFind(tag.toString()));

    scope cached = dub.newTest();
    cached.loadPackage();
    assert(cached.project.hasAllDependencies);
    cached.upgrade(UpgradeOptions.select | UpgradeOptions.upgrade);
    assert(cached.fs.readText(SelectionsPath) == lockfile);

    // Even a new project/lockfile can get a pin from the downloaded cache.
    scope unselected = dub.newTest((scope Filesystem fs) { fs.removeFile(SelectionsPath); });
    unselected.loadPackage();
    unselected.upgrade(UpgradeOptions.select);
    assert(unselected.fs.readText(SelectionsPath) == lockfile);
}

// Legacy extracted caches remain usable offline, without inventing a digest.
unittest
{
    scope dub = newProject();
    dub.fs.writePackageFile("b", "1.0.0", `{"name":"b","version":"1.0.0"}`);
    dub.loadPackage();
    dub.upgrade(UpgradeOptions.select);
    assert(dub.project.selections.getIntegrityTag(PackageName("b")) == IntegrityTag.init);
    assert(!dub.fs.readText(SelectionsPath).canFind("integrity"));

    const tag = IntegrityTag.make(cast(const(ubyte)[]) "trusted original archive", "sha256");
    writePin(dub, "1.0.0", tag);
    scope pinned = dub.newTest();
    pinned.loadPackage();
    assert(pinned.project.hasAllDependencies);
    pinned.upgrade(UpgradeOptions.select);
    assert(pinned.project.selections.getIntegrityTag(PackageName("b")) == tag);
    assert(pinned.fs.readText(SelectionsPath).canFind(tag.toString()));
}

// A changed download fails before installation and leaves the lockfile untouched.
unittest
{
    scope dub = newProject();
    addPackage(dub.getRegistry());
    dub.loadPackage();
    dub.upgrade(UpgradeOptions.select);
    auto pack = dub.project.getDependency("b", true);
    const packagePath = pack.path;
    const lockfile = dub.fs.readText(SelectionsPath);
    dub.remove(pack);
    assert(!dub.fs.existsDirectory(packagePath));
    assert(dub.packageManager.getPackage(PackageName("b"), Version("1.0.0")) is null);

    scope changed = dub.newTest();
    addPackage(changed.getRegistry(), "1.0.0", "retagged");
    changed.loadPackage();
    auto error = collectException(changed.upgrade(UpgradeOptions.select));
    assert(error !is null && error.msg.canFind("does not match integrity tag"));
    assert(changed.fs.readText(SelectionsPath) == lockfile);
    assert(!changed.fs.existsDirectory(packagePath));

    // Fetching the original bytes again succeeds with the existing pin.
    scope original = dub.newTest();
    original.loadPackage();
    addPackage(original.getRegistry());
    original.upgrade(UpgradeOptions.select);
    assert(original.fs.readText(SelectionsPath) == lockfile);
}

// Externally supplied algorithms work on download and after restarting from cache.
unittest
{
    foreach (algorithm; ["sha256", "sha384", "sha512"])
    {
        scope dub = newProject();
        addPackage(dub.getRegistry());
        const name = PackageName("b");
        const ver = Version("1.0.0");
        auto data = dub.getRegistry().fetchPackage(name, VersionRange(ver, ver), false);
        const tag = IntegrityTag.make(data, algorithm);
        writePin(dub, "1.0.0", tag);
        dub.loadPackage();
        dub.upgrade(UpgradeOptions.select);
        assert(dub.project.selections.getIntegrityTag(name) == tag);

        scope cached = dub.newTest();
        cached.loadPackage();
        cached.upgrade(UpgradeOptions.select);
        assert(cached.project.selections.getIntegrityTag(name) == tag);
        assert(cached.fs.readText(SelectionsPath).canFind(tag.toString()));
    }
}

// A cache known to come from a different archive cannot satisfy a pin.
unittest
{
    scope dub = newProject();
    addPackage(dub.getRegistry());
    dub.fetch(PackageName("b"), Version("1.0.0"));
    writePin(dub, "1.0.0", IntegrityTag.make(cast(const(ubyte)[]) "different archive"));
    scope cached = dub.newTest();
    auto error = collectException(cached.loadPackage());
    assert(error !is null && error.msg.canFind("does not match integrity tag"));
}

// New versions get new pins, whether first downloaded or already cached.
unittest
{
    foreach (precache; [false, true])
    {
        scope dub = newProject();
        addPackage(dub.getRegistry());
        dub.loadPackage();
        dub.upgrade(UpgradeOptions.select);
        const oldTag = dub.project.selections.getIntegrityTag(PackageName("b"));
        addPackage(dub.getRegistry(), "1.1.0", "new version");
        if (precache) dub.fetch(PackageName("b"), Version("1.1.0"));
        dub.upgrade(UpgradeOptions.select | UpgradeOptions.upgrade);
        assert(dub.project.getDependency("b", true).version_ == Version("1.1.0"));
        const newTag = dub.project.selections.getIntegrityTag(PackageName("b"));
        assert(newTag != IntegrityTag.init && newTag != oldTag);
        assert(dub.fs.readText(SelectionsPath).canFind(newTag.toString()));
    }
}

// An explicit branch upgrade can replace a snapshot pinned under the same name.
unittest
{
    scope dub = newProject("~master");
    addPackage(dub.getRegistry(), "~master");
    dub.loadPackage();
    dub.upgrade(UpgradeOptions.select);
    const oldTag = dub.project.selections.getIntegrityTag(PackageName("b"));
    addPackage(dub.getRegistry(), "~master", "new snapshot");
    dub.upgrade(UpgradeOptions.select);
    assert(dub.project.selections.getIntegrityTag(PackageName("b")) == oldTag);
    dub.upgrade(UpgradeOptions.select | UpgradeOptions.upgrade);
    const newTag = dub.project.selections.getIntegrityTag(PackageName("b"));
    assert(newTag != IntegrityTag.init && newTag != oldTag);
    assert(dub.fs.readText(dub.project.getDependency("b", true).path ~ "source.d") == "new snapshot");
}

// Pins cannot disappear through malformed selections or an unavailable version.
unittest
{
    scope dub = newProject();
    dub.fs.writeFile(SelectionsPath,
        `{"fileVersion":1,"versions":{"b":{"version":"1.0.0","integrity":"sha512-invalid"}}}`);
    assertThrown!Exception(dub.loadPackage());

    writePin(dub, "1.0.0", IntegrityTag.make(cast(const(ubyte)[]) "archive"));
    const lockfile = dub.fs.readText(SelectionsPath);
    dub.loadPackage();
    assertThrown!Exception(dub.upgrade(UpgradeOptions.select));
    assert(dub.fs.readText(SelectionsPath) == lockfile);
}

// Direct storage also generates hashes, and ignores metadata supplied in the ZIP.
unittest
{
    scope dub = newProject();
    dub.getRegistry().add(Version("1.0.0"), (scope Filesystem fs) {
        fs.writeFile(NativePath("dub.json"), `{"name":"b"}`);
        fs.writeFile(NativePath(PackageManager.IntegrityFilename), "forged metadata");
    });
    const name = PackageName("b");
    const ver = Version("1.0.0");
    auto data = dub.getRegistry().fetchPackage(name, VersionRange(ver, ver), false);
    auto pack = dub.packageManager.store(data, PlacementLocation.user, name, ver);
    assert(dub.packageManager.getIntegrityTag(pack) == IntegrityTag.make(data));
}

// Explicit placement and the cached-fetch fast path both preserve integrity.
unittest
{
    scope dub = newProject();
    addPackage(dub.getRegistry());
    IntegrityTag tag;
    auto pack = dub.fetch(PackageName("b"), Version("1.0.0"), FetchOptions.none,
        PlacementLocation.local, tag);
    assert(pack.path.startsWith(TestDub.ProjectPath ~ ".dub/packages/"));
    assert(tag != IntegrityTag.init);
    IntegrityTag cachedTag;
    assert(dub.fetch(PackageName("b"), Version("1.0.0"), FetchOptions.none,
        PlacementLocation.local, cachedTag).path == pack.path);
    assert(cachedTag == tag);
    auto incorrect = IntegrityTag.make(cast(const(ubyte)[]) "wrong archive");
    assertThrown!Exception(dub.fetch(PackageName("b"), Version("1.0.0"), FetchOptions.none,
        PlacementLocation.local, incorrect));
}

// Dry runs and noSaveSelections must not write a new lockfile.
unittest
{
    scope dub = newProject();
    addPackage(dub.getRegistry());
    dub.loadPackage();
    dub.upgrade(UpgradeOptions.select | UpgradeOptions.dryRun);
    assert(!dub.fs.existsFile(SelectionsPath));
    assert(dub.packageManager.getPackage(PackageName("b"), Version("1.0.0")) is null);
    dub.upgrade(UpgradeOptions.select | UpgradeOptions.noSaveSelections);
    assert(!dub.fs.existsFile(SelectionsPath));
    assert(dub.project.selections.getIntegrityTag(PackageName("b")) != IntegrityTag.init);
}

// A corrupt ZIP attempt cannot set the output pin or poison the next attempt.
unittest
{
    foreach (alwaysCorrupt; [false, true])
    {
        auto supplier = new RetryingSupplier();
        supplier.alwaysCorrupt = alwaysCorrupt;
        addPackage(supplier);
        scope dub = new TestDub(null, TestDub.ProjectPath.toNativeString(),
            [supplier], SkipPackageSuppliers.all);
        IntegrityTag tag;
        if (alwaysCorrupt)
        {
            assertThrown!Exception(dub.fetch(PackageName("b"), VersionRange.Any,
                FetchOptions.none, PlacementLocation.user, tag));
            assert(supplier.requests == 3);
            assert(tag == IntegrityTag.init);
            assert(dub.packageManager.getPackage(PackageName("b"), Version("1.0.0")) is null);
        }
        else
        {
            auto pack = dub.fetch(PackageName("b"), VersionRange.Any,
                FetchOptions.none, PlacementLocation.user, tag);
            assert(supplier.requests == 2);
            assert(tag != IntegrityTag.init);
            assert(dub.packageManager.getIntegrityTag(pack) == tag);
        }
    }
}

// Extraction/recipe failures remove the partial installation, including metadata.
unittest
{
    import std.zip : ZipArchive, ArchiveMember;
    scope dub = newProject();
    auto archive = new ZipArchive();
    auto recipe = new ArchiveMember();
    recipe.name = "dub.json";
    recipe.expandedData = cast(ubyte[]) `{invalid recipe}`.dup;
    archive.addMember(recipe);
    auto data = cast(ubyte[]) archive.build();
    assertThrown!Exception(dub.packageManager.store(data, PlacementLocation.user,
        PackageName("b"), Version("1.0.0")));
    assert(!dub.fs.existsDirectory(dub.packageManager.getPackagePath(
        PlacementLocation.user, PackageName("b"), "1.0.0")));

    // A subpackage can fail after the main package has loaded successfully.
    recipe.expandedData = cast(ubyte[]) `{"name":"b","subPackages":["missing/"]}`.dup;
    data = cast(ubyte[]) archive.build();
    assertThrown!Exception(dub.packageManager.store(data, PlacementLocation.user,
        PackageName("b"), Version("1.0.0")));
    assert(dub.packageManager.getPackage(PackageName("b"), Version("1.0.0")) is null);
}

// Subpackages share the main archive's pin, including after a fresh cache load.
unittest
{
    scope dub = new TestDub((scope Filesystem fs) {
        fs.writeFile(TestDub.ProjectPath ~ "dub.json",
            `{"name":"a","dependencies":{"b:sub":"~>1.0"}}`);
    });
    dub.getRegistry().add(Version("1.0.0"), (scope Filesystem fs) {
        fs.writeFile(NativePath("dub.json"), `{"name":"b","subPackages":[{"name":"sub"}]}`);
    });
    dub.loadPackage();
    dub.upgrade(UpgradeOptions.select);
    const tag = dub.project.selections.getIntegrityTag(PackageName("b"));
    assert(tag != IntegrityTag.init);
    scope cached = dub.newTest();
    cached.loadPackage();
    assert(cached.project.hasAllDependencies);
    assert(cached.packageManager.getIntegrityTag(cached.project.getDependency("b:sub", true)) == tag);
}
