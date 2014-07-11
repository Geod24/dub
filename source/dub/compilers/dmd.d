/**
	DMD compiler support.

	Copyright: © 2013-2013 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.compilers.dmd;

import dub.compilers.compiler;
import dub.internal.utils;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.inet.path;
import dub.platform;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.process;
import std.random;
import std.typecons;


class DmdCompiler : Compiler {
	private static immutable s_options = [
		tuple(BuildOptions.debugMode, ["-debug"]),
		tuple(BuildOptions.releaseMode, ["-release"]),
		tuple(BuildOptions.coverage, ["-cov"]),
		tuple(BuildOptions.debugInfo, ["-g"]),
		tuple(BuildOptions.debugInfoC, ["-gc"]),
		tuple(BuildOptions.alwaysStackFrame, ["-gs"]),
		tuple(BuildOptions.stackStomping, ["-gx"]),
		tuple(BuildOptions.inline, ["-inline"]),
		tuple(BuildOptions.noBoundsCheck, ["-noboundscheck"]),
		tuple(BuildOptions.optimize, ["-O"]),
		tuple(BuildOptions.profile, ["-profile"]),
		tuple(BuildOptions.unittests, ["-unittest"]),
		tuple(BuildOptions.verbose, ["-v"]),
		tuple(BuildOptions.ignoreUnknownPragmas, ["-ignore"]),
		tuple(BuildOptions.syntaxOnly, ["-o-"]),
		tuple(BuildOptions.warnings, ["-wi"]),
		tuple(BuildOptions.warningsAsErrors, ["-w"]),
		tuple(BuildOptions.ignoreDeprecations, ["-d"]),
		tuple(BuildOptions.deprecationWarnings, ["-dw"]),
		tuple(BuildOptions.deprecationErrors, ["-de"]),
		tuple(BuildOptions.property, ["-property"]),
	];

	override @property string name() const { return "dmd"; }
	override protected @property string binary() const { return m_binary; }
	private immutable string m_binary;
	this(string bin) { this.m_binary = bin; }

	BuildPlatform determinePlatform(ref BuildSettings settings, string compiler_binary, string arch_override)
	{
		import std.process;
		import std.string;

		auto fil = generatePlatformProbeFile();

		string[] arch_flags;

		switch (arch_override) {
			default: throw new Exception("Unsupported architecture: "~arch_override);
			case "": break;
			case "x86": arch_flags = ["-m32"]; break;
			case "x86_64": arch_flags = ["-m64"]; break;
		}
		settings.addDFlags(arch_flags);

		auto result = executeShell(escapeShellCommand(compiler_binary ~ arch_flags ~ ["-quiet", "-run", fil.toNativeString()]));
		enforce(result.status == 0, format("Failed to invoke the compiler %s to determine the build platform: %s",
			compiler_binary, result.output));

		auto build_platform = readPlatformProbe(result.output);
		build_platform.compilerBinary = compiler_binary;

		if (build_platform.compiler != this.name) {
			logWarn(`The determined compiler type "%s" doesn't match the expected type "%s". This will probably result in build errors.`,
				build_platform.compiler, this.name);
		}

		if (arch_override.length && !build_platform.architecture.canFind(arch_override)) {
			logWarn(`Failed to apply the selected architecture %s. Got %s.`,
				arch_override, build_platform.architecture);
		}

		return build_platform;
	}

	void prepareBuildSettings(ref BuildSettings settings, BuildSetting fields = BuildSetting.all) const
	{
		enforceBuildRequirements(settings);

		if (!(fields & BuildSetting.options)) {
			foreach (t; s_options)
				if (settings.options & t[0])
					settings.addDFlags(t[1]);
		}

		if (!(fields & BuildSetting.versions)) {
			settings.addDFlags(settings.versions.map!(s => "-version="~s)().array());
			settings.versions = null;
		}

		if (!(fields & BuildSetting.debugVersions)) {
			settings.addDFlags(settings.debugVersions.map!(s => "-debug="~s)().array());
			settings.debugVersions = null;
		}

		if (!(fields & BuildSetting.importPaths)) {
			settings.addDFlags(settings.importPaths.map!(s => "-I"~s)().array());
			settings.importPaths = null;
		}

		if (!(fields & BuildSetting.stringImportPaths)) {
			settings.addDFlags(settings.stringImportPaths.map!(s => "-J"~s)().array());
			settings.stringImportPaths = null;
		}

		if (!(fields & BuildSetting.sourceFiles)) {
			settings.addDFlags(settings.sourceFiles);
			settings.sourceFiles = null;
		}

		if (!(fields & BuildSetting.libs)) {
			resolveLibs(settings);
			version(Windows) settings.addSourceFiles(settings.libs.map!(l => l~".lib")().array());
			else settings.addLFlags(settings.libs.map!(l => "-l"~l)().array());
		}

		if (!(fields & BuildSetting.lflags)) {
			settings.addDFlags(settings.lflags.map!(f => "-L"~f)().array());
			settings.lflags = null;
		}

		assert(fields & BuildSetting.dflags);
		assert(fields & BuildSetting.copyFiles);
	}

	void extractBuildOptions(ref BuildSettings settings) const {
		DmdCompiler.extractBuildOptions_(settings);
	}
	static void extractBuildOptions_(ref BuildSettings settings) {
		Appender!(string[]) newflags;
		next_flag: foreach (f; settings.dflags) {
			foreach (t; s_options)
				if (t[1].canFind(f)) {
					settings.options |= t[0];
					continue next_flag;
				}
			if (f.startsWith("-version=")) settings.addVersions(f[9 .. $]);
			else if (f.startsWith("-debug=")) settings.addDebugVersions(f[7 .. $]);
			else newflags ~= f;
		}
		settings.dflags = newflags.data;
	}

	void setTarget(ref BuildSettings settings, in BuildPlatform platform, string tpath = null) const
	{
		final switch (settings.targetType) {
			case TargetType.autodetect: assert(false, "Invalid target type: autodetect");
			case TargetType.none: assert(false, "Invalid target type: none");
			case TargetType.sourceLibrary: assert(false, "Invalid target type: sourceLibrary");
			case TargetType.executable: break;
			case TargetType.library:
			case TargetType.staticLibrary:
				settings.addDFlags("-lib");
				break;
			case TargetType.dynamicLibrary:
				version (Windows) settings.addDFlags("-shared");
				else settings.addDFlags("-shared", "-fPIC");
				break;
		}

		if (tpath is null)
			tpath = (Path(settings.targetPath) ~ getTargetFileName(settings, platform)).toNativeString();
		settings.addDFlags("-of"~tpath);
	}

	void invoke(in BuildSettings settings, in BuildPlatform platform, void delegate(int, string) output_callback)
	{
		auto res_file = getTempDir() ~ ("dub-build-"~uniform(0, uint.max).to!string~"-.rsp");
		std.file.write(res_file.toNativeString(), join(settings.dflags.map!(s => s.canFind(' ') ? "\""~s~"\"" : s), "\n"));
		scope (exit) remove(res_file.toNativeString());

		logDiagnostic("%s %s", platform.compilerBinary, join(cast(string[])settings.dflags, " "));
		invokeTool([platform.compilerBinary, "@"~res_file.toNativeString()], output_callback);
	}

	void invokeLinker(in BuildSettings settings, in BuildPlatform platform, string[] objects, void delegate(int, string) output_callback)
	{
		import std.string;
		auto tpath = Path(settings.targetPath) ~ getTargetFileName(settings, platform);
		auto args = [platform.compiler, "-of"~tpath.toNativeString()];
		args ~= objects;
		args ~= settings.sourceFiles;
		version(linux) args ~= "-L--no-as-needed"; // avoids linker errors due to libraries being speficied in the wrong order by DMD
		args ~= settings.lflags.map!(l => "-L"~l)().array;
		args ~= settings.dflags.filter!(f => isLinkerDFlag(f)).array;
		logDiagnostic("%s", args.join(" "));
		invokeTool(args, output_callback);
	}

	private static bool isLinkerDFlag(string arg)
	{
		switch (arg) {
			default:
				if (arg.startsWith("-defaultlib=")) return true;
				return false;
			case "-g", "-gc", "-m32", "-m64", "-shared", "-lib":
				return true;
		}
	}
}
