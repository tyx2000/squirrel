// Purpose: A small JSON value type with a parser and serializer, enough for the history
// and settings files without pulling in a third-party library.

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace space::json {

class Value {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Value() = default;
    static Value Bool(bool value);
    static Value Number(double value);
    static Value String(std::string value);
    static Value Array();
    static Value Object();

    Type type() const { return type_; }
    bool IsNull() const { return type_ == Type::Null; }
    bool IsBool() const { return type_ == Type::Bool; }
    bool IsNumber() const { return type_ == Type::Number; }
    bool IsString() const { return type_ == Type::String; }
    bool IsArray() const { return type_ == Type::Array; }
    bool IsObject() const { return type_ == Type::Object; }

    bool AsBool(bool fallback = false) const { return type_ == Type::Bool ? bool_ : fallback; }
    double AsNumber(double fallback = 0) const { return type_ == Type::Number ? number_ : fallback; }
    const std::string& AsString() const { return string_; }

    // Arrays.
    size_t Size() const { return values_.size(); }
    const Value& At(size_t index) const { return values_[index]; }
    void Append(Value value);

    // Objects keep insertion order.
    const Value* Find(std::string_view key) const;
    void Set(std::string key, Value value);
    const std::vector<std::string>& Keys() const { return keys_; }
    const Value& ValueAt(size_t index) const { return values_[index]; }

private:
    Type type_ = Type::Null;
    bool bool_ = false;
    double number_ = 0;
    std::string string_;
    std::vector<std::string> keys_;  // objects only
    std::vector<Value> values_;      // array elements, or object values matching keys_
};

std::optional<Value> Parse(std::string_view text);
std::string Serialize(const Value& value);

}  // namespace space::json
