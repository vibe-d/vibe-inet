/**
	HTML character entity escaping.

	TODO: Make things @safe once Appender is.

	Copyright: © 2012-2014 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.textfilter.html;

import std.array;
import std.conv;
import std.range;


/** Returns the HTML escaped version of a given string.
*/
string htmlEscape(R)(R str) @trusted
	if (isInputRange!R)
{
	if (__ctfe) { // appender is a performance/memory hog in ctfe
		StringAppender dst;
		filterHTMLEscape(dst, str);
		return dst.data;
	} else {
		auto dst = appender!string();
		filterHTMLEscape(dst, str);
		return dst.data;
	}
}

///
unittest {
	assert(htmlEscape(`"Hello", <World>!`) == `"Hello", &lt;World&gt;!`);
}


/** Writes the HTML escaped version of a given string to an output range.
*/
void filterHTMLEscape(R, S)(ref R dst, S str, HTMLEscapeFlags flags = HTMLEscapeFlags.escapeNewline)
	if (isOutputRange!(R, dchar) && isInputRange!S)
{
	for (;!str.empty;str.popFront())
		filterHTMLEscape(dst, str.front, flags);
}


/** Returns the HTML escaped version of a given string (also escapes double quotes).
*/
string htmlAttribEscape(R)(R str) @trusted
	if (isInputRange!R)
{
	if (__ctfe) { // appender is a performance/memory hog in ctfe
		StringAppender dst;
		filterHTMLAttribEscape(dst, str);
		return dst.data;
	} else {
		auto dst = appender!string();
		filterHTMLAttribEscape(dst, str);
		return dst.data;
	}
}

///
unittest {
	assert(htmlAttribEscape(`"Hello", <World>!`) == `&quot;Hello&quot;, &lt;World&gt;!`);
}


/** Writes the HTML escaped version of a given string to an output range (also escapes double quotes).
*/
void filterHTMLAttribEscape(R, S)(ref R dst, S str)
	if (isOutputRange!(R, dchar) && isInputRange!S)
{
	for (; !str.empty; str.popFront())
		filterHTMLEscape(dst, str.front, HTMLEscapeFlags.escapeNewline|HTMLEscapeFlags.escapeQuotes);
}


/** Returns the HTML escaped version of a given string (escapes every character).
*/
string htmlAllEscape(R)(R str) @trusted
	if (isInputRange!R)
{
	if (__ctfe) { // appender is a performance/memory hog in ctfe
		StringAppender dst;
		filterHTMLAllEscape(dst, str);
		return dst.data;
	} else {
		auto dst = appender!string();
		filterHTMLAllEscape(dst, str);
		return dst.data;
	}
}

///
unittest {
	assert(htmlAllEscape("Hello!") == "&#72;&#101;&#108;&#108;&#111;&#33;");
}


/** Writes the HTML escaped version of a given string to an output range (escapes every character).
*/
void filterHTMLAllEscape(R, S)(ref R dst, S str)
	if (isOutputRange!(R, dchar) && isInputRange!S)
{
	for (; !str.empty; str.popFront()) {
		put(dst, "&#");
		put(dst, to!string(cast(uint)str.front));
		put(dst, ';');
	}
}


/**
	Minimally escapes a text so that no HTML tags appear in it.
*/
string htmlEscapeMin(R)(R str) @trusted
	if (isInputRange!R)
{
	auto dst = appender!string();
	for (; !str.empty; str.popFront())
		filterHTMLEscape(dst, str.front, HTMLEscapeFlags.escapeMinimal);
	return dst.data();
}


/**
	Writes the HTML escaped version of a character to an output range.
*/
void filterHTMLEscape(R)(ref R dst, dchar ch, HTMLEscapeFlags flags = HTMLEscapeFlags.escapeNewline )
{
	switch (ch) {
		default:
			if (flags & HTMLEscapeFlags.escapeUnknown) {
				put(dst, "&#");
				put(dst, to!string(cast(uint)ch));
				put(dst, ';');
			} else put(dst, ch);
			break;
		case '"':
			if (flags & HTMLEscapeFlags.escapeQuotes) put(dst, "&quot;");
			else put(dst, '"');
			break;
		case '\'':
			if (flags & HTMLEscapeFlags.escapeQuotes) put(dst, "&#39;");
			else put(dst, '\'');
			break;
		case '\r', '\n':
			if (flags & HTMLEscapeFlags.escapeNewline) {
				put(dst, "&#");
				put(dst, to!string(cast(uint)ch));
				put(dst, ';');
			} else put(dst, ch);
			break;
		case 'a': .. case 'z': goto case;
		case 'A': .. case 'Z': goto case;
		case '0': .. case '9': goto case;
		case ' ', '\t', '-', '_', '.', ':', ',', ';',
			 '#', '+', '*', '?', '=', '(', ')', '/', '!',
			 '%' , '{', '}', '[', ']', '`', '$', '^', '~':
			put(dst, cast(char)ch);
			break;
		case '<': put(dst, "&lt;"); break;
		case '>': put(dst, "&gt;"); break;
		case '&': put(dst, "&amp;"); break;
	}
}


enum HTMLEscapeFlags {
	escapeMinimal = 0,
	escapeQuotes = 1<<0,
	escapeNewline = 1<<1,
	escapeUnknown = 1<<2
}

private struct StringAppender {
@safe:

	string data;
	void put(string s) { data ~= s; }
	void put(char ch) { data ~= ch; }
	void put(dchar ch) {
		import std.utf;
		char[4] dst;
		data ~= dst[0 .. encode(dst, ch)];
	}
}


unittest {
	// ASCII special characters
	auto str1 = "!\"#$%&'()*+,-./:;<=>?[\\]^_`{|}~";
	assert(htmlEscape(str1) == "!\"#$%&amp;'()*+,-./:;&lt;=&gt;?[\\]^_`{|}~");
	assert(htmlAttribEscape(str1) == "!&quot;#$%&amp;&#39;()*+,-./:;&lt;=&gt;?[\\]^_`{|}~");

	// non-ASCII special characters
	auto str2 = " ¡¢£¤¥¦§¨©ª«¬­®¯°±²³´µ¶·¸¹º»¼½¾¿";
	assert(htmlEscape(str2) == str2);
}
