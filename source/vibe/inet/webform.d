/**
	Contains HTML/urlencoded form parsing and construction routines.

	Copyright: © 2012-2014 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Jan Krüger
*/
module vibe.inet.webform;

import vibe.container.dictionarylist;
import vibe.core.file;
import vibe.core.log;
import vibe.core.path;
import vibe.inet.message;
import vibe.internal.string;
import vibe.internal.interfaceproxy : InterfaceProxy, interfaceProxy;
import vibe.stream.operations;
import vibe.textfilter.urlencode;

import std.array;
import std.typecons : tuple;
import std.exception;
import std.range : isInputRange, isOutputRange, only, ElementType;
import std.string;
import std.sumtype : SumType;
import std.traits : ValueType, KeyType;
import std.variant : Variant, variantArray;


/**
	Parses form data according 	to an HTTP Content-Type header.

	Writes the form fields into a key-value of type $(D FormFields), parsed from the
	specified $(D InputStream) and using the corresponding Content-Type header. Parsing
	is gracefully aborted if the Content-Type header is unrelated.

	Params:
		fields = The key-value map to which form fields must be written
		files = The $(D FilePart)s mapped to the corresponding key in which details on
				transmitted files will be written to.
		content_type = The value of the Content-Type HTTP header.
		body_reader = A valid $(D InputSteram) data stream consumed by the parser.
		max_line_length = The byte-sized maximum length of lines used as boundary delimitors in Multi-Part forms.
*/
bool parseFormData(ref FormFields fields, ref FilePartFormFields files, string content_type, InputStream body_reader, size_t max_line_length)
@safe {
	auto ct_entries = content_type.split(";");
	if (!ct_entries.length) return false;

	switch (ct_entries[0].strip()) {
		default:
			return false;
		case "application/x-www-form-urlencoded":
			assert(!!body_reader);
			parseURLEncodedForm(body_reader.readAllUTF8(), fields);
			break;
		case "multipart/form-data":
			assert(!!body_reader);
			parseMultiPartForm(fields, files, content_type, body_reader, max_line_length);
			break;
	}
	return false;
}

/**
	Parses a URL encoded form and stores the key/value pairs.

	Writes to the $(D FormFields) the key-value map associated to an
	"application/x-www-form-urlencoded" MIME formatted string, ie. all '+'
	characters are considered as ' ' spaces.
*/
void parseURLEncodedForm(string str, ref FormFields params)
@safe {
	while (str.length > 0) {
		// name part
		auto idx = str.indexOf("=");
		if (idx == -1) {
			idx = vibe.internal.string.indexOfAny(str, "&;");
			if (idx == -1) {
				params.addField(formDecode(str[0 .. $]), "");
				return;
			} else {
				params.addField(formDecode(str[0 .. idx]), "");
				str = str[idx+1 .. $];
				continue;
			}
		} else {
			auto idx_amp = vibe.internal.string.indexOfAny(str, "&;");
			if (idx_amp > -1 && idx_amp < idx) {
				params.addField(formDecode(str[0 .. idx_amp]), "");
				str = str[idx_amp+1 .. $];
				continue;
			} else {
				string name = formDecode(str[0 .. idx]);
				str = str[idx+1 .. $];
				// value part
				for( idx = 0; idx < str.length && str[idx] != '&' && str[idx] != ';'; idx++) {}
				string value = formDecode(str[0 .. idx]);
				params.addField(name, value);
				str = idx < str.length ? str[idx+1 .. $] : null;
			}
		}
	}
}

/**
	This example demonstrates parsing using all known form separators, it builds
	a key-value map into the destination $(D FormFields)
*/
unittest
{
	FormFields dst;
	parseURLEncodedForm("a=b;c;dee=asd&e=fgh&f=j%20l", dst);
	assert("a" in dst && dst["a"] == "b");
	assert("c" in dst && dst["c"] == "");
	assert("dee" in dst && dst["dee"] == "asd");
	assert("e" in dst && dst["e"] == "fgh");
	assert("f" in dst && dst["f"] == "j l");
}


/**
	Parses a form in "multipart/form-data" format.

	If any files are contained in the form, they are written to temporary files using
	$(D vibe.core.file.createTempFile) and their details returned in the files field.

	Params:
		fields = The key-value map to which form fields must be written
		files = The $(D FilePart)s mapped to the corresponding key in which details on
				transmitted files will be written to.
		content_type = The value of the Content-Type HTTP header.
		body_reader = A valid $(D InputStream) data stream consumed by the parser.
		max_line_length = The byte-sized maximum length of lines used as boundary delimitors in Multi-Part forms.
*/
void parseMultiPartForm(InputStream)(ref FormFields fields, ref FilePartFormFields files,
	string content_type, InputStream body_reader, size_t max_line_length)
	if (isInputStream!InputStream)
{
	import std.algorithm : strip;

	auto pos = content_type.indexOf("boundary=");
	enforce(pos >= 0 , "no boundary for multipart form found");
	auto boundary = content_type[pos+9 .. $].strip('"');
	auto firstBoundary = () @trusted { return cast(string)body_reader.readLine(max_line_length); } ();
	enforce(firstBoundary == "--" ~ boundary, "Invalid multipart form data!");

	while (parseMultipartFormPart(body_reader, fields, files, cast(const(ubyte)[])("\r\n--" ~ boundary), max_line_length)) {}
}

alias FormFields = DictionaryList!(string, true, 16);
alias FilePartFormFields = DictionaryList!(FilePart, true, 0);

@safe unittest
{
	import vibe.stream.memory;

	auto content_type = "multipart/form-data; boundary=\"AaB03x\"";

	auto input = createMemoryStream(cast(ubyte[])(
			"--AaB03x\r\n" ~
			"Content-Disposition: form-data; name=\"submit-name\"\r\n" ~
			"\r\n" ~
			"Larry\r\n" ~
			"--AaB03x\r\n" ~
			"Content-Disposition: form-data; name=\"files\"; filename=\"file1.txt\"\r\n" ~
			"Content-Type: text/plain\r\n" ~
			"\r\n" ~
			"... contents of file1.txt ...\r\n" ~
			"--AaB03x--\r\n").dup, false);

	FormFields fields;
	FilePartFormFields files;

	parseMultiPartForm(fields, files, content_type, input, 4096);

	assert(fields["submit-name"] == "Larry");
	assert(files["files"].filename == "file1.txt");
}

unittest { // issue #1220 - wrong handling of Content-Length
	import vibe.stream.memory;

	auto content_type = "multipart/form-data; boundary=\"AaB03x\"";

	auto input = createMemoryStream(cast(ubyte[])(
			"--AaB03x\r\n" ~
			"Content-Disposition: form-data; name=\"submit-name\"\r\n" ~
			"\r\n" ~
			"Larry\r\n" ~
			"--AaB03x\r\n" ~
			"Content-Disposition: form-data; name=\"files\"; filename=\"file1.txt\"\r\n" ~
			"Content-Type: text/plain\r\n" ~
			"Content-Length: 29\r\n" ~
			"\r\n" ~
			"... contents of file1.txt ...\r\n" ~
			"--AaB03x--\r\n" ~
			"Content-Disposition: form-data; name=\"files\"; filename=\"file2.txt\"\r\n" ~
			"Content-Type: text/plain\r\n" ~
			"\r\n" ~
			"... contents of file1.txt ...\r\n" ~
			"--AaB03x--\r\n").dup, false);

	FormFields fields;
	FilePartFormFields files;

	parseMultiPartForm(fields, files, content_type, input, 4096);

	assert(fields["submit-name"] == "Larry");
	assert(files["files"].filename == "file1.txt");
}

unittest { // use of unquoted strings in Content-Disposition
	import vibe.stream.memory;

	auto content_type = "multipart/form-data; boundary=\"AaB03x\"";

	auto input = createMemoryStream(cast(ubyte[])(
			"--AaB03x\r\n" ~
			"Content-Disposition: form-data; name=submitname\r\n" ~
			"\r\n" ~
			"Larry\r\n" ~
			"--AaB03x\r\n" ~
			"Content-Disposition: form-data; name=files; filename=file1.txt\r\n" ~
			"Content-Type: text/plain\r\n" ~
			"Content-Length: 29\r\n" ~
			"\r\n" ~
			"... contents of file1.txt ...\r\n" ~
			"--AaB03x--\r\n").dup, false);

	FormFields fields;
	FilePartFormFields files;

	parseMultiPartForm(fields, files, content_type, input, 4096);

	assert(fields["submitname"] == "Larry");
	assert(files["files"].filename == "file1.txt");
}

/**
	Single part of a multipart form.

	A FilePart is the data structure for individual "multipart/form-data" parts
	according to RFC 1867 section 7.
*/
struct FilePart {
	InetHeaderMap headers;
	NativePath.Segment filename;
	NativePath tempPath;

	// avoids NativePath.Segment.toString() being called
	string toString() const { return filename.name; }
}


private bool parseMultipartFormPart(InputStream)(InputStream stream, ref FormFields form, ref FilePartFormFields files, const(ubyte)[] boundary, size_t max_line_length)
	if (isInputStream!InputStream)
{
	//find end of quoted string
	auto indexOfQuote(string str) {
		foreach (i, ch; str) {
			if (ch == '"' && (i == 0 || str[i-1] != '\\')) return i;
		}
		return -1;
	}

	auto parseValue(ref string str) {
		string res;
		if (str[0]=='"') {
			str = str[1..$];
			auto pos = indexOfQuote(str);
			res = str[0..pos].replace(`\"`, `"`);
			str = str[pos..$];
		}
		else {
			auto pos = str.indexOf(';');
			if (pos < 0) {
				res = str;
				str = "";
			} else {
				res = str[0 .. pos];
				str = str[pos..$];
			}
		}

		return res;
	}

	InetHeaderMap headers;
	stream.parseRFC5322Header(headers);
	auto pv = "Content-Disposition" in headers;
	enforce(pv, "invalid multipart");
	auto cd = *pv;
	string name;
	auto pos = cd.indexOf("name=");
	if (pos >= 0) {
		cd = cd[pos+5 .. $];
		name = parseValue(cd);
	}
	string filename;
	pos = cd.indexOf("filename=");
	if (pos >= 0) {
		cd = cd[pos+9 .. $];
		filename = parseValue(cd);
	}

	if (filename.length > 0) {
		FilePart fp;
		fp.headers = headers;
		version (Have_vibe_core)
			fp.filename = NativePath.Segment(filename);
		else
			fp.filename = PathEntry.validateFilename(filename);

		auto file = createTempFile();
		fp.tempPath = file.path;
		if (auto plen = "Content-Length" in headers) {
			import std.conv : to;
			stream.pipe(file, (*plen).to!long);
			enforce(stream.skipBytes(boundary), "Missing multi-part end boundary marker.");
		} else stream.readUntil(file, boundary);
		logDebug("file: %s", fp.tempPath.toString());
		file.close();

		files.addField(name, fp);

		// TODO: temp files must be deleted after the request has been processed!
	} else {
		auto data = () @trusted { return cast(string)stream.readUntil(boundary); } ();
		form.addField(name, data);
	}

	ubyte[2] ub;
	stream.read(ub, IOMode.all);
	if (ub == "--")
	{
		stream.pipe(nullSink());
		return false;
	}
	enforce(ub == cast(const(ubyte)[])"\r\n");
	return true;
}

/**
	Encodes a Key-Value map into a form URL encoded string.

	Writes to the $(D OutputRange) an application/x-www-form-urlencoded MIME formatted string,
	ie. all spaces ' ' are replaced by the '+' character

	Params:
		dst	= The destination $(D OutputRange) where the resulting string must be written to.
		map	= An iterable key-value map iterable with $(D foreach(string key, string value; map)).
		sep	= A valid form separator, common values are '&' or ';'
*/
void formEncode(R, T)(auto ref R dst, T map, char sep = '&')
	if (isFormMap!T && isOutputRange!(R, char))
{
	formEncodeImpl(dst, map, sep, true);
}

/**
	The following example demonstrates the use of $(D formEncode) with a json map,
	the ordering of keys will be preserved in $(D Bson) and $(D DictionaryList) objects only.
 */
unittest {
	import std.array : Appender;
	string[string] map;
	map["numbers"] = "123456789";
	map["spaces"] = "1 2 3 4 a b c d";

	Appender!string app;
	app.formEncode(map);
	assert(app.data == "spaces=1+2+3+4+a+b+c+d&numbers=123456789" ||
		   app.data == "numbers=123456789&spaces=1+2+3+4+a+b+c+d");
}

/**
	Encodes a Key-Value map into a form URL encoded string.

	Returns an application/x-www-form-urlencoded MIME formatted string,
	ie. all spaces ' ' are replaced by the '+' character

	Params:
		map = An iterable key-value map iterable with $(D foreach(string key, string value; map)).
		sep = A valid form separator, common values are '&' or ';'
*/
string formEncode(T)(T map, char sep = '&')
	if (isFormMap!T)
{
	return formEncodeImpl(map, sep, true);
}

/// Ditto
string formEncode(T : DictionaryList!Args, Args...)(T map, char sep = '&')
{
	return formEncodeImpl(map.byKeyValue(), sep, true);
}

/**
	Writes to the $(D OutputRange) an URL encoded string as specified in RFC 3986 section 2

	Params:
		dst	= The destination $(D OutputRange) where the resulting string must be written to.
		map	= An iterable key-value map iterable with $(D foreach(string key, string value; map)).
*/
void urlEncode(R, T)(auto ref R dst, T map)
	if (isFormMap!T && isOutputRange!(R, char))
{
	formEncodeImpl(dst, map, "&", false);
}


/**
	Returns an URL encoded string as specified in RFC 3986 section 2

	Params:
		map = An iterable key-value map iterable with $(D foreach(string key, string value; map)).
*/
string urlEncode(T)(T map)
	if (isFormMap!T)
{
	return formEncodeImpl(map, '&', false);
}

/// Ditto
string urlEncode(T : DictionaryList!Args, Args...)(T map)
{
	return formEncodeImpl(map.byKeyValue, '&', false);
}

/**
	Tests if a given type is suitable for storing a web form.

	Types that define iteration support with the key typed as $(D string) and
	the value either also typed as $(D string), or as a $(D vibe.data.json.Json)
	like value. The latter case specifically requires a $(D .type) property that
	is tested for equality with $(D T.Type.string), as well as a
	$(D .get!string) method.
*/
template isFormMap(T)
{
	import std.conv;
	enum isFormMap = isStringMap!T || isJsonLike!T;
}

private template isStringMap(T)
{
	enum isStringMap = __traits(compiles, () {
		foreach (string key, string value; T.init) {}
	} ());
}

unittest {
	static assert(isStringMap!(string[string]));

	static struct M {
		int opApply(int delegate(string key, string value)) { return 0; }
	}
	static assert(isStringMap!M);
}

private template isJsonLike(T)
{
	enum isJsonLike = __traits(compiles, () {
		import std.conv;
		string r;
		foreach (string key, value; T.init)
			r = value.type == T.Type.string ? value.get!string : value.to!string;
	} ());
}

unittest {
	import vibe.data.json;
	import vibe.data.bson;
	static assert(isJsonLike!Json);
	static assert(isJsonLike!Bson);
}

private string formEncodeImpl(T)(T map, char sep, bool form_encode)
	if (isStringMap!T)
{
	import std.array : Appender;
	Appender!string dst;
	size_t len;

	foreach (key, ref value; map) {
		len += key.length;
		len += value.length;
	}

	// characters will be expanded, better use more space the first time and avoid additional allocations
	dst.reserve(len*2);
	dst.formEncodeImpl(map, sep, form_encode);
	return dst.data;
}


private string formEncodeImpl(T)(T map, char sep, bool form_encode)
	if (isJsonLike!T)
{
	import std.array : Appender;
	Appender!string dst;
	size_t len;

	foreach (string key, T value; map) {
		len += key.length;
		len += value.length;
	}

	// characters will be expanded, better use more space the first time and avoid additional allocations
	dst.reserve(len*2);
	dst.formEncodeImpl(map, sep, form_encode);
	return dst.data;
}

private void formEncodeImpl(R, T)(auto ref R dst, T map, char sep, bool form_encode)
	if (isOutputRange!(R, string) && isStringMap!T)
{
	bool flag;

	foreach (key, value; map) {
		if (flag)
			dst.put(sep);
		else
			flag = true;
		filterURLEncode(dst, key, null, form_encode);
		dst.put("=");
		filterURLEncode(dst, value, null, form_encode);
	}
}

private void formEncodeImpl(R, T)(auto ref R dst, T map, char sep, bool form_encode)
	if (isOutputRange!(R, string) && isJsonLike!T)
{
	bool flag;

	foreach (string key, T value; map) {
		if (flag)
			dst.put(sep);
		else
			flag = true;
		filterURLEncode(dst, key, null, form_encode);
		dst.put("=");
		if (value.type == T.Type.string)
			filterURLEncode(dst, value.get!string, null, form_encode);
		else {
			static if (T.stringof == "Json")
				filterURLEncode(dst, value.to!string, null, form_encode);
			else
				filterURLEncode(dst, value.toString(), null, form_encode);

		}
	}
}

unittest
{
	import vibe.data.json : Json;
	import vibe.data.bson : Bson;
	import std.algorithm.sorting : sort;

	string[string] aaMap;
	DictionaryList!string dlMap;
	Json jsonMap = Json.emptyObject;
	Bson bsonMap = Bson.emptyObject;

	aaMap["unicode"] = "╤╳";
	aaMap["numbers"] = "123456789";
	aaMap["spaces"] = "1 2 3 4 a b c d";
	aaMap["slashes"] = "1/2/3/4/5";
	aaMap["equals"] = "1=2=3=4=5=6=7";
	aaMap["complex"] = "╤╳/=$$\"'1!2()'\"";
	aaMap["╤╳"] = "1";


	dlMap["unicode"] = "╤╳";
	dlMap["numbers"] = "123456789";
	dlMap["spaces"] = "1 2 3 4 a b c d";
	dlMap["slashes"] = "1/2/3/4/5";
	dlMap["equals"] = "1=2=3=4=5=6=7";
	dlMap["complex"] = "╤╳/=$$\"'1!2()'\"";
	dlMap["╤╳"] = "1";


	jsonMap["unicode"] = "╤╳";
	jsonMap["numbers"] = "123456789";
	jsonMap["spaces"] = "1 2 3 4 a b c d";
	jsonMap["slashes"] = "1/2/3/4/5";
	jsonMap["equals"] = "1=2=3=4=5=6=7";
	jsonMap["complex"] = "╤╳/=$$\"'1!2()'\"";
	jsonMap["╤╳"] = "1";

	bsonMap["unicode"] = "╤╳";
	bsonMap["numbers"] = "123456789";
	bsonMap["spaces"] = "1 2 3 4 a b c d";
	bsonMap["slashes"] = "1/2/3/4/5";
	bsonMap["equals"] = "1=2=3=4=5=6=7";
	bsonMap["complex"] = "╤╳/=$$\"'1!2()'\"";
	bsonMap["╤╳"] = "1";

	assert(urlEncode(aaMap).split('&').sort().join("&") == "%E2%95%A4%E2%95%B3=1&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&numbers=123456789&slashes=1%2F2%2F3%2F4%2F5&spaces=1%202%203%204%20a%20b%20c%20d&unicode=%E2%95%A4%E2%95%B3");
	assert(urlEncode(dlMap) == "unicode=%E2%95%A4%E2%95%B3&numbers=123456789&spaces=1%202%203%204%20a%20b%20c%20d&slashes=1%2F2%2F3%2F4%2F5&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&%E2%95%A4%E2%95%B3=1");
	assert(urlEncode(jsonMap).split('&').sort().join("&") == "%E2%95%A4%E2%95%B3=1&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&numbers=123456789&slashes=1%2F2%2F3%2F4%2F5&spaces=1%202%203%204%20a%20b%20c%20d&unicode=%E2%95%A4%E2%95%B3");
	assert(urlEncode(bsonMap) == "unicode=%E2%95%A4%E2%95%B3&numbers=123456789&spaces=1%202%203%204%20a%20b%20c%20d&slashes=1%2F2%2F3%2F4%2F5&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&%E2%95%A4%E2%95%B3=1");
	{
		FormFields aaFields;
		parseURLEncodedForm(urlEncode(aaMap), aaFields);
		assert(urlEncode(aaMap) == urlEncode(aaFields));

		FormFields dlFields;
		parseURLEncodedForm(urlEncode(dlMap), dlFields);
		assert(urlEncode(dlMap) == urlEncode(dlFields));

		FormFields jsonFields;
		parseURLEncodedForm(urlEncode(jsonMap), jsonFields);
		assert(urlEncode(jsonMap) == urlEncode(jsonFields));

		FormFields bsonFields;
		parseURLEncodedForm(urlEncode(bsonMap), bsonFields);
		assert(urlEncode(bsonMap) == urlEncode(bsonFields));
	}

	assert(formEncode(aaMap).split('&').sort().join("&") == "%E2%95%A4%E2%95%B3=1&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&numbers=123456789&slashes=1%2F2%2F3%2F4%2F5&spaces=1+2+3+4+a+b+c+d&unicode=%E2%95%A4%E2%95%B3");
	assert(formEncode(dlMap) == "unicode=%E2%95%A4%E2%95%B3&numbers=123456789&spaces=1+2+3+4+a+b+c+d&slashes=1%2F2%2F3%2F4%2F5&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&%E2%95%A4%E2%95%B3=1");
	assert(formEncode(jsonMap).split('&').sort().join("&") == "%E2%95%A4%E2%95%B3=1&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&numbers=123456789&slashes=1%2F2%2F3%2F4%2F5&spaces=1+2+3+4+a+b+c+d&unicode=%E2%95%A4%E2%95%B3");
	assert(formEncode(bsonMap) == "unicode=%E2%95%A4%E2%95%B3&numbers=123456789&spaces=1+2+3+4+a+b+c+d&slashes=1%2F2%2F3%2F4%2F5&equals=1%3D2%3D3%3D4%3D5%3D6%3D7&complex=%E2%95%A4%E2%95%B3%2F%3D%24%24%22%271%212%28%29%27%22&%E2%95%A4%E2%95%B3=1");

	{
		FormFields aaFields;
		parseURLEncodedForm(formEncode(aaMap), aaFields);
		assert(formEncode(aaMap) == formEncode(aaFields));

		FormFields dlFields;
		parseURLEncodedForm(formEncode(dlMap), dlFields);
		assert(formEncode(dlMap) == formEncode(dlFields));

		FormFields jsonFields;
		parseURLEncodedForm(formEncode(jsonMap), jsonFields);
		assert(formEncode(jsonMap) == formEncode(jsonFields));

		FormFields bsonFields;
		parseURLEncodedForm(formEncode(bsonMap), bsonFields);
		assert(formEncode(bsonMap) == formEncode(bsonFields));
	}

}

/**
	An HTTP multipart/form-data is like tree with up to 3 levels.
	Tree-Nodes include: multipart/form-data for the form itself and multipart/mixed when multiple
	files are attached to the same form input.
	Leaf-nodes in the Multipart tree: simple-text and files.
*/
bool isMultipartBodyType(T)() {
	static if (isInputRange!(T) && is(ElementType!(T) == MultipartEntity!(HeaderT, BodyT), HeaderT, BodyT)) {
		return isStringMap!(HeaderT) && isMultipartBodyType!(BodyT);
    } else static if (is(ElementType!(T) == Variant)) {
		// TODO: Figure out a better alternative than a blanket allowance for Variant
		return true;
	} else {
		return is(T : string)
				|| isInputStream!T;
	}
}

/**
	A top-level multipart entity containing one or more HTTP entities of different types.

	In the context of HTTP, only the type "multipart/form-data" is used, which is composed of simple
	values such as form text input or form checkbox input with default Content-Type of "text/plain",
	single files with types like "application/pdf", or a set of files under a multipart entity of
	type "multipart/mixed". In the context of email, it is common for "multipart/mixed" and
	"multipart/alternative" to be used to form a tree of data, with each leaf node having a concrete
	content-type such as "text/plain" or "application/pdf".

	Closely related to the MIME entity specification, this entity has a "Content-Type" header value
	in the form "multipart/*", e.g. "multipart/form-data". Following RFC 2046, this entity represents
	one or more different data parts combined into a single body. RFC 2388 describes the details of
	the "multipart/form-data" content-type, which uses the "Content-Disposition" header to indicate
	which form field each part describes.

	A boundary value preceeded by "--" is used to separate the multipart body parts, and the last
	part is indicated by the boundary value also followed by "--". An example HTTP POST request
	is shown below:
	```
	POST /upload HTTP/1.1
	Content-Length: 428
	Content-Type: multipart/form-data; boundary=abcde12345

	--abcde12345
	Content-Disposition: form-data; name="id"
	Content-Type: text/plain
	123e4567-e89b-12d3-a456-426655440000
	--abcde12345
	Content-Disposition: form-data; name="address"
	Content-Type: application/json
	{
	"street": "3, Garden St",
	"city": "Hillsbery, UT"
	}
	--abcde12345
	Content-Disposition: form-data; name="profileImage "; filename="image1.png"
	Content-Type: application/octet-stream
	{…file content…}
	--abcde12345--
	```

	A single piece of a MultipartEntity, containing another MIME entity. For example, a single entity
	with the "multipart/form-data" might contain 3 parts, one with MIME type "application/json",
	another with "text/plain", and the last with "application/octet-stream".

	A part is like a normal MIME entity, composed of headers and a body, with the following rules:
	- There may be 0 headers, in such cases, the "Content-Type" defaults to "text/plain; charset=US-ASCII".
	- The boundary delimiter must NOT appear in the body.

	For 'multipart/form-data', additional rules apply from RFC2388:
	- Each MulipartEntityPart must contain a "Content-Disposition" header, e.g.
		 ```
		 Content-Disposition: form-data; name="user"
		 ```
	- Each part's "Content-Disposition" header should have the type "form-data".
	- Each part's "Content-Disposition" header should have a parameter "name" matching the original
		 HTML form input/select name.

	Params:
	HeaderT = The type to use to represent headers. The default value is `InetHeaderMap`, which is
	    a struct using a static-array, and avoids dynamic memory allocations when there are fewer
		than 32 headers.

	See_Also: https://datatracker.ietf.org/doc/html/rfc2046#section-5.1
	See_Also: https://www.w3.org/Protocols/rfc1341/7_2_Multipart.html
	See_Also: https://datatracker.ietf.org/doc/html/rfc2388
*/
struct MultipartEntity(HeaderT = InetHeaderMap)
if (isStringMap!HeaderT)
{
	HeaderT headers;
	Variant bodyValue;

	/// If the entity is a multipart entity, the boundary string to use. It is kept here so that
	/// it does not have to be read from the headers each time it is needed.
	string boundary;

	/// MultipartEntities should be constructed using factory methods.
	private this(BodyT)(HeaderT headers, BodyT bodyValue, string boundary = "") {
		this.headers = headers;
		this.bodyValue = bodyValue;
		this.boundary = boundary;
	}

	/** Returns the mime type part of the 'Content-Type' header.

		This function gets the pure mime type (e.g. "text/plain")
		without any supplimentary parameters such as "charset=...".
		Use contentTypeParameters to get any parameter string or
		headers["Content-Type"] to get the raw value.
	*/
	// @property string contentType()
	// const {
	// 	auto pv = "Content-Type" in headers;
	// 	if( !pv ) return "text/plain";
	// 	auto idx = std.string.indexOf(*pv, ';');
	// 	return idx >= 0 ? (*pv)[0 .. idx] : *pv;
	// }

	/// ditto
	// @property void contentType(string ct) { headers["Content-Type"] = ct; }

	/** Returns any supplementary parameters of the 'Content-Type' header.

		This is a semicolon separated ist of key/value pairs. Usually, if set,
		this contains the character set used for text based content types.
	*/
	// @property string contentTypeParameters()
	// const {
	// 	auto pv = "Content-Type" in headers;
	// 	if( !pv ) return "charset=US-ASCII";
	// 	auto idx = std.string.indexOf(*pv, ';');
	// 	return idx >= 0 ? (*pv)[idx+1 .. $] : null;
	// }
}


////
// Multipart Factory Methods
////

// /// Returns a MultipartEntity with Content-Type "multipart/form-data" from parts as a compile-time sequence.
// auto multipartFormData(MultipartR...)(MultipartR parts) {
// 	return multipartFormData(parts);
// }

// ///
// unittest {
// 	import vibe.stream.memory;
// 	// Build an entity using the var-args form.
// 	auto entity = multipartFormData(
// 			multipartFormInput("name", "Bob Jones"),
// 			multipartFormFile("resume", formFile("Resume-Bob.pdf", "application/pdf")),
// 			multipartFormFiles("photos", [
// 					formFile("portrait1.jpg", createMemoryStream(cast(ubyte[]) "dummy data"), "image/png"),
// 					formFile("portrait2.jpg", createMemoryStream(cast(ubyte[]) "dummy data"), "image/png"),
// 					]),
// 			);
// }

/// Returns a MultipartEntity with Content-Type "multipart/form-data" from parts as a range.
auto multipartFormData(MultipartR)(MultipartR parts)
if (isInputRange!MultipartR && isMultipartBodyType!(MultipartR)) {
	string boundaryStr = createBoundaryString();
	auto headers = only(
			tuple("Content-Type", "multipart/form-data; boundary=" ~ boundaryStr));
	return MultipartEntity!(typeof(headers))(headers: headers, bodyValue: parts, boundary: boundaryStr);
}

///
unittest {
	import vibe.stream.memory;

	// Build an entity using the var-args form.
	auto entity = multipartFormData(variantArray(
			multipartFormInput("name", "Bob Jones"),
			multipartFormFile("resume", formFile("Resume-Bob.pdf", createMemoryStream(cast(ubyte[]) "dummy data"), "application/pdf")),
			multipartFormFiles("photos", [
					formFile("portrait1.jpg", createMemoryStream(cast(ubyte[]) "dummy data"), "image/png"),
					formFile("portrait2.jpg", createMemoryStream(cast(ubyte[]) "dummy data"), "image/png"),
					]),
			));
}

/// Creates a multipart entity part as a named form item.
static auto multipartFormInput(T)(string name, T v) {
	import std.conv : to;
	static assert(__traits(compiles, to!string(T.init)), "Type '" ~ T.stringof ~ "' must be convertible to a string!");
	auto headers = only(
			tuple("Content-Disposition", "form-data; name=" ~ name));
	return MultipartEntity!(typeof(headers))(headers: headers, bodyValue: v.to!string);
}

/// A convenience type to make it easier to group data about a file in a form.
struct FormFile(InputStreamT)
if (isInputStream!InputStreamT) {
	string fileName;
	InputStreamT fileStream;
	string contentType;
}

/// Creates a FormFile by opening a file specified by `filePath`.
auto formFile(string filePath, string contentType = "") {
	import std.path : baseName;
	import vibe.core.file : openFile;
	string fileName = baseName(filePath);
	auto fileStream = interfaceProxy!InputStream(openFile(filePath));
	return formFile(fileName, fileStream, contentType);
}

/// Creates a FormFile object which is used when attaching multiple files to a multipart form input field.
auto formFile(StreamT)(string fileName, StreamT fileStream, string contentType = "")
if (isInputStream!StreamT) {
	import vibe.inet.mimetypes : getMimeTypeForFile;
	if (contentType == "") {
		contentType = getMimeTypeForFile(fileName);
	}
	return FormFile!(StreamT)(fileName, fileStream, contentType);
}

/// A builder method creating a part by loading a file from a stream.
auto multipartFormFile(StreamT)(string name, FormFile!StreamT formFile)
if (isInputStream!StreamT) {
	auto headers = only(
			tuple("Content-Type", formFile.contentType),
			tuple("Content-Disposition", "form-data; name=" ~ name ~ "; filename=" ~ formFile.fileName),
			// For now, take the file as-is using the "binary" encoding:
			// https://datatracker.ietf.org/doc/html/rfc2045#section-2.9
			tuple("Content-Transfer-Encoding", "binary"));
	return MultipartEntity!(typeof(headers))(
			headers: headers, bodyValue: formFile.fileStream);
}

// TODO: Using this causes an error.
// ```
// Error: forward reference to inferred return type of function call `multipartFormFiles(name, __param_1, __param_2)`
// ```
auto multipartFormFiles(FormFileR...)(string name, FormFileR formFiles) {
	return multipartFormFiles(name, formFiles);
}

/// Creates a MultipartEntity consisting of several files for the same form input.
auto multipartFormFiles(FormFileR)(string name, FormFileR formFiles) {
	static assert(isInputRange!FormFileR, "Type '" ~ FormFileR.stringof ~ "' is not an input range!");
	enum isFormFileElem = is(ElementType!FormFileR == FormFile!StreamT, StreamT);
	static assert(isFormFileElem, "Type '" ~ (ElementType!FormFileR).stringof ~ "' must have elements of type FormFile!InputStream.");
	static assert(isInputStream!StreamT, "Type '" ~ StreamT.stringof ~ "' is not InputStream-compatible!");
	import std.algorithm : map;

	string boundaryStr = createBoundaryString();
	auto headers = only(
			tuple("Content-Type", "multipart/mixed; boundary=" ~ boundaryStr),
			tuple("Content-Disposition", "form-data; name=" ~ name));
	auto multipartFormFileRange = formFiles.map!(formFile => multipartFormFile(name, formFile));
	return MultipartEntity!(typeof(headers))(
			headers: headers,
			bodyValue: multipartFormFileRange,
			boundary: boundaryStr);
}

/**
   Boundary delimiters can be up to 70 characters.
   https://datatracker.ietf.org/doc/html/rfc2046#section-5.1.1
   > The only mandatory global parameter for the "multipart" media type is
   > the boundary parameter, which consists of 1 to 70 characters from a
   > set of characters known to be very robust through mail gateways
*/
private string createBoundaryString() {
	import std.conv : to;
	import std.ascii : letters, digits;
	import std.range : chain;
	import std.random : randomSample;

	return randomSample(chain(letters.to!(dchar[]), digits.to!(dchar[])), 50)
			.to!string;
}
