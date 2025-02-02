
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * Composes nodes from YAML events provided by parser.
 * Code based on PyYAML: http://www.pyyaml.org
 */
module dub.internal.dyaml.composer;

import core.memory;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.format;
import std.range;
import std.typecons;

import dub.internal.dyaml.constructor;
import dub.internal.dyaml.event;
import dub.internal.dyaml.exception;
import dub.internal.dyaml.node;
import dub.internal.dyaml.parser;
import dub.internal.dyaml.resolver;


package:

///Composes YAML documents from events provided by a Parser.
struct Composer
{
    private:
        ///Parser providing YAML events.
        Parser parser_;
        ///Resolver resolving tags (data types).
        Resolver resolver_;
        ///Nodes associated with anchors. Used by YAML aliases.
        Node[string] anchors_;

        ///Used to reduce allocations when creating pair arrays.
        ///
        ///We need one appender for each nesting level that involves
        ///a pair array, as the inner levels are processed as a
        ///part of the outer levels. Used as a stack.
        Appender!(Node.Pair[])[] pairAppenders_;
        ///Used to reduce allocations when creating node arrays.
        ///
        ///We need one appender for each nesting level that involves
        ///a node array, as the inner levels are processed as a
        ///part of the outer levels. Used as a stack.
        Appender!(Node[])[] nodeAppenders_;

    public:
        /**
         * Construct a composer.
         *
         * Params:  parser      = Parser to provide YAML events.
         *          resolver    = Resolver to resolve tags (data types).
         */
        this(Parser parser, Resolver resolver) @safe nothrow
        {
            parser_ = parser;
            resolver_ = resolver;
        }

        /**
         * Determine if there are any nodes left.
         *
         * Must be called before loading as it handles the stream start event.
         */
        bool checkNode() @safe
        {
            // If next event is stream start, skip it
            parser_.skipOver!"a.id == b"(EventID.streamStart);

            //True if there are more documents available.
            return parser_.front.id != EventID.streamEnd;
        }

        ///Get a YAML document as a node (the root of the document).
        Node getNode() @safe
        {
            //Get the root node of the next document.
            assert(parser_.front.id != EventID.streamEnd,
                   "Trying to get a node from Composer when there is no node to " ~
                   "get. use checkNode() to determine if there is a node.");

            return composeDocument();
        }

        /// Set file name.
        ref inout(string) name() inout @safe return pure nothrow @nogc
        {
            return parser_.name;
        }
        /// Get a mark from the current reader position
        Mark mark() const @safe pure nothrow @nogc
        {
            return parser_.mark;
        }

        /// Get resolver
        ref Resolver resolver() @safe return pure nothrow @nogc {
            return resolver_;
        }

    private:

        void skipExpected(const EventID id) @safe
        {
            const foundExpected = parser_.skipOver!"a.id == b"(id);
            assert(foundExpected, text("Expected ", id, " not found."));
        }
        ///Ensure that appenders for specified nesting levels exist.
        ///
        ///Params:  pairAppenderLevel = Current level in the pair appender stack.
        ///         nodeAppenderLevel = Current level the node appender stack.
        void ensureAppendersExist(const uint pairAppenderLevel, const uint nodeAppenderLevel)
            @safe
        {
            while(pairAppenders_.length <= pairAppenderLevel)
            {
                pairAppenders_ ~= appender!(Node.Pair[])();
            }
            while(nodeAppenders_.length <= nodeAppenderLevel)
            {
                nodeAppenders_ ~= appender!(Node[])();
            }
        }

        ///Compose a YAML document and return its root node.
        Node composeDocument() @safe
        {
            skipExpected(EventID.documentStart);

            //Compose the root node.
            Node node = composeNode(0, 0);

            skipExpected(EventID.documentEnd);

            anchors_.destroy();
            return node;
        }

        /// Compose a node.
        ///
        /// Params: pairAppenderLevel = Current level of the pair appender stack.
        ///         nodeAppenderLevel = Current level of the node appender stack.
        Node composeNode(const uint pairAppenderLevel, const uint nodeAppenderLevel) @safe
        {
            if(parser_.front.id == EventID.alias_)
            {
                const event = parser_.front;
                parser_.popFront();
                const anchor = event.anchor;
                enforce((anchor in anchors_) !is null,
                        new ComposerException("Found undefined alias: " ~ anchor,
                                              event.startMark));

                //If the node referenced by the anchor is uninitialized,
                //it's not finished, i.e. we're currently composing it
                //and trying to use it recursively here.
                enforce(anchors_[anchor] != Node(),
                        new ComposerException(text("Found recursive alias: ", anchor),
                              event.startMark, "defined here", anchors_[anchor].startMark));

                return anchors_[anchor];
            }

            const event = parser_.front;
            const anchor = event.anchor;
            if((anchor !is null) && (anchor in anchors_) !is null)
            {
                throw new ComposerException(text("Found duplicate anchor: ", anchor),
                    event.startMark, "defined here", anchors_[anchor].startMark);
            }

            Node result;
            //Associate the anchor, if any, with an uninitialized node.
            //used to detect duplicate and recursive anchors.
            if(anchor !is null)
            {
                Node tempNode;
                tempNode.startMark_ = event.startMark;
                anchors_[anchor] = tempNode;
            }

            switch (parser_.front.id)
            {
                case EventID.scalar:
                    result = composeScalarNode();
                    break;
                case EventID.sequenceStart:
                    result = composeSequenceNode(pairAppenderLevel, nodeAppenderLevel);
                    break;
                case EventID.mappingStart:
                    result = composeMappingNode(pairAppenderLevel, nodeAppenderLevel);
                    break;
                default: assert(false, "This code should never be reached");
            }

            if(anchor !is null)
            {
                anchors_[anchor] = result;
            }
            return result;
        }

        ///Compose a scalar node.
        Node composeScalarNode() @safe
        {
            const event = parser_.front;
            parser_.popFront();
            const tag = resolver_.resolve(NodeID.scalar, event.tag, event.value,
                                          event.implicit);

            Node node = constructNode(event.startMark, event.endMark, tag,
                                          event.value);
            node.scalarStyle = event.scalarStyle;

            return node;
        }

        /// Compose a sequence node.
        ///
        /// Params: pairAppenderLevel = Current level of the pair appender stack.
        ///         nodeAppenderLevel = Current level of the node appender stack.
        Node composeSequenceNode(const uint pairAppenderLevel, const uint nodeAppenderLevel)
            @safe
        {
            ensureAppendersExist(pairAppenderLevel, nodeAppenderLevel);
            auto nodeAppender = &(nodeAppenders_[nodeAppenderLevel]);

            const startEvent = parser_.front;
            parser_.popFront();
            const tag = resolver_.resolve(NodeID.sequence, startEvent.tag, null,
                                          startEvent.implicit);

            while(parser_.front.id != EventID.sequenceEnd)
            {
                nodeAppender.put(composeNode(pairAppenderLevel, nodeAppenderLevel + 1));
            }

            Node node = constructNode(startEvent.startMark, parser_.front.endMark,
                                          tag, nodeAppender.data.dup);
            node.collectionStyle = startEvent.collectionStyle;
            parser_.popFront();
            nodeAppender.clear();

            return node;
        }

        /**
         * Flatten a node, merging it with nodes referenced through YAMLMerge data type.
         *
         * Node must be a mapping or a sequence of mappings.
         *
         * Params:  root              = Node to flatten.
         *          startMark         = Start position of the node.
         *          endMark           = End position of the node.
         *          pairAppenderLevel = Current level of the pair appender stack.
         *          nodeAppenderLevel = Current level of the node appender stack.
         *
         * Returns: Flattened mapping as pairs.
         */
        Node.Pair[] flatten(ref Node root, const Mark startMark, const Mark endMark,
                            const uint pairAppenderLevel, const uint nodeAppenderLevel) @safe
        {
            void error(Node node)
            {
                //this is Composer, but the code is related to Constructor.
                throw new ConstructorException("While constructing a mapping, " ~
                   "expected a mapping or a list of " ~
                   "mappings for merging, but found: " ~
                   text(node.type),
                   endMark, "mapping started here", startMark);
            }

            ensureAppendersExist(pairAppenderLevel, nodeAppenderLevel);
            auto pairAppender = &(pairAppenders_[pairAppenderLevel]);

            final switch (root.nodeID)
            {
                case NodeID.mapping:
                    Node[] toMerge;
                    toMerge.reserve(root.length);
                    foreach (ref Node key, ref Node value; root)
                    {
                        if(key.type == NodeType.merge)
                        {
                            toMerge ~= value;
                        }
                        else
                        {
                            auto temp = Node.Pair(key, value);
                            pairAppender.put(temp);
                        }
                    }
                    foreach (node; toMerge)
                    {
                        pairAppender.put(flatten(node, startMark, endMark,
                                                     pairAppenderLevel + 1, nodeAppenderLevel));
                    }
                    break;
                case NodeID.sequence:
                    foreach (ref Node node; root)
                    {
                        if (node.nodeID != NodeID.mapping)
                        {
                            error(node);
                        }
                        pairAppender.put(flatten(node, startMark, endMark,
                                                     pairAppenderLevel + 1, nodeAppenderLevel));
                    }
                    break;
                case NodeID.scalar:
                case NodeID.invalid:
                    error(root);
                    break;
            }

            auto flattened = pairAppender.data.dup;
            pairAppender.clear();

            return flattened;
        }

        /// Compose a mapping node.
        ///
        /// Params: pairAppenderLevel = Current level of the pair appender stack.
        ///         nodeAppenderLevel = Current level of the node appender stack.
        Node composeMappingNode(const uint pairAppenderLevel, const uint nodeAppenderLevel)
            @safe
        {
            ensureAppendersExist(pairAppenderLevel, nodeAppenderLevel);
            const startEvent = parser_.front;
            parser_.popFront();
            const tag = resolver_.resolve(NodeID.mapping, startEvent.tag, null,
                                          startEvent.implicit);
            auto pairAppender = &(pairAppenders_[pairAppenderLevel]);

            Tuple!(Node, Mark)[] toMerge;
            while(parser_.front.id != EventID.mappingEnd)
            {
                auto pair = Node.Pair(composeNode(pairAppenderLevel + 1, nodeAppenderLevel),
                                      composeNode(pairAppenderLevel + 1, nodeAppenderLevel));

                //Need to flatten and merge the node referred by YAMLMerge.
                if(pair.key.type == NodeType.merge)
                {
                    toMerge ~= tuple(pair.value, cast(Mark)parser_.front.endMark);
                }
                //Not YAMLMerge, just add the pair.
                else
                {
                    pairAppender.put(pair);
                }
            }
            foreach(node; toMerge)
            {
                merge(*pairAppender, flatten(node[0], startEvent.startMark, node[1],
                                             pairAppenderLevel + 1, nodeAppenderLevel));
            }

            auto sorted = pairAppender.data.dup.sort!((x,y) => x.key > y.key);
            if (sorted.length)
            {
                foreach (index, const ref value; sorted[0 .. $ - 1].enumerate)
                    if (value.key == sorted[index + 1].key)
                    {
                        throw new ComposerException(
                            text("Key '", value.key.get!string, "' appears multiple times in mapping"),
                                sorted[index + 1].key.startMark, "defined here", value.key.startMark);
                    }
            }

            Node node = constructNode(startEvent.startMark, parser_.front.endMark,
                                          tag, pairAppender.data.dup);
            node.collectionStyle = startEvent.collectionStyle;
            parser_.popFront();

            pairAppender.clear();
            return node;
        }
}

// Provide good error message on multiple keys (which JSON supports)
@safe unittest
{
    import dub.internal.dyaml.loader : Loader;

    const str = `{
    "comment": "This is a common technique",
    "name": "foobar",
    "comment": "To write down comments pre-JSON5"
}`;

    const exc = collectException!LoaderException(Loader.fromString(str).load());
    assert(exc);
    assert(exc.message() ==
       "Unable to load <unknown>: Key 'comment' appears multiple times in mapping\n" ~
       "<unknown>:4,5\ndefined here: <unknown>:2,5");
}

// Provide good error message on duplicate anchors
@safe unittest
{
    import dub.internal.dyaml.loader : Loader;

    const str = `{
    a: &anchor b,
    b: &anchor c,
}`;

    const exc = collectException!LoaderException(Loader.fromString(str).load());
    assert(exc);
    assert(exc.message() ==
       "Unable to load <unknown>: Found duplicate anchor: anchor\n" ~
       "<unknown>:3,8\ndefined here: <unknown>:2,8");
}

// Provide good error message on missing alias
@safe unittest
{
    import dub.internal.dyaml.loader : Loader;

    const str = `{
    a: *anchor,
}`;

    const exc = collectException!LoaderException(Loader.fromString(str).load());
    assert(exc);
    assert(exc.message() ==
       "Unable to load <unknown>: Found undefined alias: anchor\n" ~
       "<unknown>:2,8");
}

// Provide good error message on recursive alias
@safe unittest
{
    import dub.internal.dyaml.loader : Loader;

    const str = `a: &anchor {
    b: *anchor
}`;

    const exc = collectException!LoaderException(Loader.fromString(str).load());
    assert(exc);
    assert(exc.message() ==
       "Unable to load <unknown>: Found recursive alias: anchor\n" ~
       "<unknown>:2,8\ndefined here: <unknown>:1,4");
}

// Provide good error message on failed merges
@safe unittest
{
    import dub.internal.dyaml.loader : Loader;

    const str = `a: &anchor 3
b: { <<: *anchor }`;

    const exc = collectException!LoaderException(Loader.fromString(str).load());
    assert(exc);
    assert(exc.message() ==
       "Unable to load <unknown>: While constructing a mapping, expected a mapping or a list of mappings for merging, but found: integer\n" ~
       "<unknown>:2,19\nmapping started here: <unknown>:2,4");
}
