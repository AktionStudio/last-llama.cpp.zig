#include "schema_api.h"
#include "json-schema-to-grammar.h"
#include "nlohmann/json.hpp"
#include <cstring>
#include <limits>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

using Json=nlohmann::ordered_json;
struct Unsupported : std::runtime_error { using std::runtime_error::runtime_error; };
static void fail(const std::string & path,const std::string & reason) { throw Unsupported(path+": "+reason); }
static void validate(const Json & s,const std::string & path,size_t depth,size_t & nodes) {
    if (++nodes>10000 || depth>64) fail(path,"SchemaComplexityExceeded");
    if (!s.is_object()) fail(path,"SchemaObjectRequired");
    if (s.contains("description") && !s["description"].is_string()) fail(path,"InvalidDescription");
    std::set<std::string> keys;
    for (auto i=s.begin();i!=s.end();++i) if(i.key()!="description") keys.insert(i.key());
    if(s.contains("anyOf")) {
        if(keys!=std::set<std::string>{"anyOf"}) fail(path,"UnsupportedAnyOfIntersection");
        if(!s["anyOf"].is_array() || s["anyOf"].empty()) fail(path,"InvalidAlternatives");
        for(size_t i=0;i<s["anyOf"].size();++i) validate(s["anyOf"][i],path+"/anyOf/"+std::to_string(i),depth+1,nodes);
        return;
    }
    if(!s.contains("type") || !s["type"].is_string()) fail(path,"SingleExplicitTypeRequired");
    const auto type=s["type"].get<std::string>();
    if(!std::set<std::string>{"null","boolean","string","integer","number","object","array"}.count(type)) fail(path,"UnsupportedType");
    if(s.contains("const") || s.contains("enum")) {
        const std::string literal=s.contains("const")?"const":"enum";
        if(keys!=std::set<std::string>{"type",literal}) fail(path,"UnsupportedLiteralIntersection");
        const auto values=literal=="const"?Json::array({s["const"]}):s["enum"];
        if(!values.is_array() || values.empty()) fail(path,"InvalidEnum");
        if(type=="array" || type=="object") fail(path,"UnsupportedCompoundLiteral");
        for(const auto & v:values) {
            const bool match=(type=="null"&&v.is_null())||(type=="boolean"&&v.is_boolean())||
                (type=="string"&&v.is_string())||(type=="integer"&&v.is_number_integer())||
                (type=="number"&&v.is_number());
            if(!match) fail(path,"LiteralTypeMismatch");
        }
        return;
    }
    std::set<std::string> allowed{"type"};
    if(type=="object") allowed.insert({"properties","required","additionalProperties"});
    if(type=="array") allowed.insert({"items","minItems","maxItems"});
    if(type=="string") allowed.insert({"minLength","maxLength"});
    if(type=="integer") allowed.insert({"minimum","maximum"});
    for(const auto & key:keys) if(!allowed.count(key)) fail(path,"UnsupportedKeyword:"+key);
    if(type=="object") {
        if(!s.contains("additionalProperties") || s["additionalProperties"]!=false) fail(path,"ClosedObjectRequired");
        if(!s.contains("properties") || !s["properties"].is_object()) fail(path,"PropertiesRequired");
        if(s.contains("required")) {
            if(!s["required"].is_array()) fail(path,"InvalidRequired");
            std::set<std::string> seen;
            for(const auto & required:s["required"]) {
                if(!required.is_string()) fail(path,"InvalidRequired");
                const auto name=required.get<std::string>();
                if(!seen.insert(name).second || !s["properties"].contains(name)) fail(path,"InvalidRequiredProperty");
            }
        }
        for(auto i=s["properties"].begin();i!=s["properties"].end();++i) validate(i.value(),path+"/properties/"+i.key(),depth+1,nodes);
    }
    if(type=="array") {
        if(!s.contains("items")) fail(path,"ArrayItemsRequired");
        validate(s["items"],path+"/items",depth+1,nodes);
    }
    const char * lo=type=="string"?"minLength":type=="array"?"minItems":type=="integer"?"minimum":nullptr;
    const char * hi=type=="string"?"maxLength":type=="array"?"maxItems":type=="integer"?"maximum":nullptr;
    if(lo) {
        for(const char * key:{lo,hi}) if(s.contains(key)) {
            const auto & value=s[key];
            if(!value.is_number_integer()) fail(path,"IntegerBoundRequired");
            if(value.is_number_unsigned() && value.get<uint64_t>()>static_cast<uint64_t>(INT64_MAX)) fail(path,"BoundOutOfRange");
            const auto number=value.get<int64_t>();
            if(type!="integer" && (number<0 || number>65536)) fail(path,"BoundOutOfRange");
        }
        if(s.contains(lo)&&s.contains(hi)&&s[lo].get<int64_t>()>s[hi].get<int64_t>()) fail(path,"InvertedBounds");
    }
}
static void write_error(char * output,size_t capacity,const char * message) noexcept {
    if(!output || !capacity) return;
    const auto length=std::min(capacity-1,std::strlen(message));
    std::memcpy(output,message,length); output[length]=0;
}
extern "C" int lab_schema_compile(const uint8_t * input,size_t size,lab_schema_result * out,char * error,size_t error_capacity) {
    if(error && error_capacity) error[0]=0;
    if(!out || out->data || out->size || !input || !size || size>8*1024*1024 || (!error && error_capacity)) {
        write_error(error,error_capacity,"InvalidArgumentOrNonemptyResult"); return LAB_SCHEMA_INVALID_ARGUMENT;
    }
    try {
        std::vector<std::set<std::string>> object_keys;
        auto callback=[&](int depth,Json::parse_event_t event,Json & parsed) {
            if(depth>256) throw Unsupported("ParseDepthExceeded");
            if(event==Json::parse_event_t::object_start) object_keys.emplace_back();
            if(event==Json::parse_event_t::object_end) object_keys.pop_back();
            if(event==Json::parse_event_t::key && !object_keys.back().insert(parsed.get<std::string>()).second) throw Unsupported("DuplicateJsonKey");
            return true;
        };
        const std::string raw(reinterpret_cast<const char *>(input),size);
        const auto schema=Json::parse(raw,callback);
        size_t nodes=0; validate(schema,"$",0,nodes);
        // Parse the same exact invocation bytes for the pinned upstream converter.
        // Admission excludes warning-producing fallback branches (pattern/allOf/ref).
        const auto grammar=json_schema_to_grammar(common_json::parse(raw),true);
        if(grammar.empty()) throw std::runtime_error("EmptyGrammar");
        auto buffer=std::make_unique<char[]>(grammar.size()+1);
        std::memcpy(buffer.get(),grammar.data(),grammar.size());buffer[grammar.size()]=0;
        out->size=grammar.size();out->data=buffer.release();return LAB_SCHEMA_OK;
    } catch(const Unsupported & e) {write_error(error,error_capacity,e.what());return LAB_SCHEMA_UNSUPPORTED;}
      catch(const Json::exception & e) {write_error(error,error_capacity,e.what());return LAB_SCHEMA_INVALID_JSON;}
      catch(const std::bad_alloc &) {write_error(error,error_capacity,"OutOfMemory");return LAB_SCHEMA_OUT_OF_MEMORY;}
      catch(const std::exception & e) {write_error(error,error_capacity,e.what());return LAB_SCHEMA_CONVERSION_FAILED;}
      catch(...) {write_error(error,error_capacity,"UnknownConversionFailure");return LAB_SCHEMA_CONVERSION_FAILED;}
}
extern "C" void lab_schema_result_clear(lab_schema_result * result) {
    if(!result) return;
    if(result->data) {
        // Clear the owned output before freeing; no grammar is cached across calls.
        volatile char * bytes=result->data;
        for(size_t i=0;i<=result->size;++i) bytes[i]=0;
        delete[] result->data;
    }
    result->data=nullptr;result->size=0;
}
