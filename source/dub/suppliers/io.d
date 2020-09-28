/**
   A module to abstract away local IO operations

   In order to make DUB testable, we need to mock IO operations
   (a.k.a. dependency injection).
   In order to do that, DUB needs to use this module for every
   IO operations: Looking up the environment, reading and writing
   files, etc...
*/
module dub.suppliers.io;

import std.conv;

import dub.internal.vibecompat.core.file;

/// Define the primitives DUB can use
interface IOSupplier
{
    /// Get a variable from the environment, or `default_` if not set
    public string getEnv (const(char)[] name, string default_) const @safe;

    /// Get a variable from the environment, `throw`s if not set
    public string getEnv (const(char)[] name) const @safe;

    /**
       Set an environment variable

       Use `null` for `value` to unset, and `""` to make it empty.

       Params:
         name = Environment variable name
         value = Value to the the variable to
    */
    public void setEnv (string name, string value);

    /// Dup the environment as an AA
    public string[string] copyEnv () /* const */ @safe;


    /// The root path of the application, where the dub instance acts
    public NativePath rootPath () const @safe;
}

/// The 'normal' implementation, used when compiling dub in non-test mode
final class FSIOSupplier : IOSupplier
{
    import std.file;
    import std.process;

    ///
    private NativePath m_rootPath;

    /// Constructor
    public this (string root_path = ".")
    {
		this.m_rootPath = NativePath(root_path);
		if (!m_rootPath.absolute)
            this.m_rootPath = NativePath(getcwd()) ~ this.m_rootPath;
    }

    ///
    public override string getEnv (const(char)[] name, string default_)
        const @safe
    {
        // Note: Not `nothrow` because `get` is not `nothrow` on Windows
        return environment.get(name, default_);
    }

    ///
    public override string getEnv (const(char)[] name)
        const @safe
    {
        return environment.get(name);
    }

    ///
    public void setEnv (string name, string value)
    {
        environment[name] = value;
    }

    ///
    public override string[string] copyEnv () const @safe
    {
        return environment.toAA();
    }

    ///
    public NativePath rootPath () const @safe
    {
        return this.m_rootPath;
    }
}

/// The mock implementation, used for testing purposes
class TestIOSupplier : IOSupplier
{
    /// Simulate an environement
    protected string[string] env;

    ///
    private NativePath m_rootPath;

    public this (string root_path = "/tmp/dubpkg/", bool useDefault = true)
    {
        this.m_rootPath = NativePath(root_path);
        if (!this.m_rootPath.absolute)
            this.m_rootPath = NativePath("/tmp/") ~ this.m_rootPath;

        if (useDefault)
        {
            this.env["HOME"] = "/home/user/";
        }
    }

    ///
    public override string getEnv (const(char)[] name, string default_)
        const @safe nothrow @nogc pure
    {
        if (auto r = name in this.env)
            return *r;
        return default_;
    }

    ///
    public override string getEnv (const(char)[] name)
        const @safe pure
    {
        if (auto r = name in this.env)
            return *r;
        throw new Exception(text("Environment variable '", name, "' not found in test env"));
    }

    ///
    public override string[string] copyEnv () /* const */ @safe
    {
        // Not `const` because `.dup` returns `const(string)[string]`...
        return this.env.dup;
    }

    ///
    public override void setEnv (string name, string value)
    {
        if (value is null)
            this.env.remove(name);
        else
            this.env[name] = value;
    }

    ///
    public NativePath rootPath () const @safe
    {
        return this.m_rootPath;
    }
}
