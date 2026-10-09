// Purpose: Implements the JSON parser and serializer declared in json.h.

#include "json.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace space::json {

Value Value::Bool(bool value) {
    Value result;
    result.type_ = Type::Bool;
    result.bool_ = value;
    return result;
}

Value Value::Number(double value) {
    Value result;
    result.type_ = Type::Number;
    result.number_ = value;
    return result;
}

Value Value::String(std::string value) {
    Value result;
    result.type_ = Type::String;
    result.string_ = std::move(value);
    return result;
}

Value Value::Array() {
    Value result;
    result.type_ = Type::Array;
    return result;
}

Value Value::Object() {
    Value result;
    result.type_ = Type::Object;
    return result;
}

void Value::Append(Value value) {
    values_.push_back(std::move(value));
}

const Value* Value::Find(std::string_view key) const {
    if (type_ != Type::Object) return nullptr;
    for (size_t i = 0; i < keys_.size(); ++i) {
        if (keys_[i] == key) return &values_[i];
    }
    return nullptr;
}

void Value::Set(std::string key, Value value) {
    for (size_t i = 0; i < keys_.size(); ++i) {
        if (keys_[i] == key) {
            values_[i] = std::move(value);
            return;
        }
    }
    keys_.push_back(std::move(key));
    values_.push_back(std::move(value));
}

namespace {

class Parser {
public:
    explicit Parser(std::string_view text) : text_(text) {}

    std::optional<Value> ParseDocument() {
        auto value = ParseValue(0);
        if (!value) return std::nullopt;
        SkipWhitespace();
        if (position_ != text_.size()) return std::nullopt;
        return value;
    }

private:
    static constexpr int kMaxDepth = 64;

    void SkipWhitespace() {
        while (position_ < text_.size()) {
            char c = text_[position_];
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
            ++position_;
        }
    }

    bool Consume(char expected) {
        SkipWhitespace();
        if (position_ < text_.size() && text_[position_] == expected) {
            ++position_;
            return true;
        }
        return false;
    }

    bool ConsumeLiteral(std::string_view literal) {
        if (text_.substr(position_, literal.size()) != literal) return false;
        position_ += literal.size();
        return true;
    }

    std::optional<Value> ParseValue(int depth) {
        if (depth > kMaxDepth) return std::nullopt;
        SkipWhitespace();
        if (position_ >= text_.size()) return std::nullopt;

        char c = text_[position_];
        if (c == '{') return ParseObject(depth);
        if (c == '[') return ParseArray(depth);
        if (c == '"') {
            auto text = ParseString();
            if (!text) return std::nullopt;
            return Value::String(std::move(*text));
        }
        if (c == 't') return ConsumeLiteral("true") ? std::optional<Value>(Value::Bool(true)) : std::nullopt;
        if (c == 'f') return ConsumeLiteral("false") ? std::optional<Value>(Value::Bool(false)) : std::nullopt;
        if (c == 'n') return ConsumeLiteral("null") ? std::optional<Value>(Value()) : std::nullopt;
        return ParseNumber();
    }

    std::optional<Value> ParseObject(int depth) {
        ++position_;  // {
        Value object = Value::Object();
        if (Consume('}')) return object;
        for (;;) {
            SkipWhitespace();
            if (position_ >= text_.size() || text_[position_] != '"') return std::nullopt;
            auto key = ParseString();
            if (!key || !Consume(':')) return std::nullopt;
            auto value = ParseValue(depth + 1);
            if (!value) return std::nullopt;
            object.Set(std::move(*key), std::move(*value));
            if (Consume(',')) continue;
            if (Consume('}')) return object;
            return std::nullopt;
        }
    }

    std::optional<Value> ParseArray(int depth) {
        ++position_;  // [
        Value array = Value::Array();
        if (Consume(']')) return array;
        for (;;) {
            auto value = ParseValue(depth + 1);
            if (!value) return std::nullopt;
            array.Append(std::move(*value));
            if (Consume(',')) continue;
            if (Consume(']')) return array;
            return std::nullopt;
        }
    }

    std::optional<Value> ParseNumber() {
        size_t start = position_;
        if (position_ < text_.size() && (text_[position_] == '-' || text_[position_] == '+')) ++position_;
        while (position_ < text_.size()) {
            char c = text_[position_];
            if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '-' || c == '+') {
                ++position_;
            } else {
                break;
            }
        }
        if (start == position_) return std::nullopt;
        std::string number(text_.substr(start, position_ - start));
        char* end = nullptr;
        double value = std::strtod(number.c_str(), &end);
        if (!end || *end != '\0' || !std::isfinite(value)) return std::nullopt;
        return Value::Number(value);
    }

    static void AppendUtf8(std::string& out, uint32_t codePoint) {
        if (codePoint < 0x80) {
            out += static_cast<char>(codePoint);
        } else if (codePoint < 0x800) {
            out += static_cast<char>(0xC0 | (codePoint >> 6));
            out += static_cast<char>(0x80 | (codePoint & 0x3F));
        } else if (codePoint < 0x10000) {
            out += static_cast<char>(0xE0 | (codePoint >> 12));
            out += static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (codePoint & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (codePoint >> 18));
            out += static_cast<char>(0x80 | ((codePoint >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (codePoint & 0x3F));
        }
    }

    std::optional<uint32_t> ParseHex4() {
        if (position_ + 4 > text_.size()) return std::nullopt;
        uint32_t value = 0;
        for (int i = 0; i < 4; ++i) {
            char c = text_[position_++];
            value <<= 4;
            if (c >= '0' && c <= '9') value |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') value |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') value |= static_cast<uint32_t>(c - 'A' + 10);
            else return std::nullopt;
        }
        return value;
    }

    std::optional<std::string> ParseString() {
        ++position_;  // opening quote
        std::string out;
        while (position_ < text_.size()) {
            char c = text_[position_++];
            if (c == '"') return out;
            if (c != '\\') {
                out += c;
                continue;
            }
            if (position_ >= text_.size()) return std::nullopt;
            char escape = text_[position_++];
            switch (escape) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    auto high = ParseHex4();
                    if (!high) return std::nullopt;
                    uint32_t codePoint = *high;
                    if (codePoint >= 0xD800 && codePoint <= 0xDBFF && position_ + 6 <= text_.size() &&
                        text_[position_] == '\\' && text_[position_ + 1] == 'u') {
                        size_t saved = position_;
                        position_ += 2;
                        auto low = ParseHex4();
                        if (low && *low >= 0xDC00 && *low <= 0xDFFF) {
                            codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (*low - 0xDC00);
                        } else {
                            position_ = saved;
                        }
                    }
                    if (codePoint >= 0xD800 && codePoint <= 0xDFFF) codePoint = 0xFFFD;
                    AppendUtf8(out, codePoint);
                    break;
                }
                default:
                    return std::nullopt;
            }
        }
        return std::nullopt;
    }

    std::string_view text_;
    size_t position_ = 0;
};

void SerializeString(std::string& out, const std::string& text) {
    out += '"';
    for (unsigned char c : text) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                    out += buffer;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    out += '"';
}

void SerializeValue(std::string& out, const Value& value) {
    switch (value.type()) {
        case Value::Type::Null: out += "null"; break;
        case Value::Type::Bool: out += value.AsBool() ? "true" : "false"; break;
        case Value::Type::Number: {
            double number = value.AsNumber();
            char buffer[32];
            if (number == std::floor(number) && std::fabs(number) < 1e15) {
                std::snprintf(buffer, sizeof(buffer), "%.0f", number);
            } else {
                std::snprintf(buffer, sizeof(buffer), "%.17g", number);
            }
            out += buffer;
            break;
        }
        case Value::Type::String: SerializeString(out, value.AsString()); break;
        case Value::Type::Array:
            out += '[';
            for (size_t i = 0; i < value.Size(); ++i) {
                if (i) out += ',';
                SerializeValue(out, value.At(i));
            }
            out += ']';
            break;
        case Value::Type::Object:
            out += '{';
            for (size_t i = 0; i < value.Keys().size(); ++i) {
                if (i) out += ',';
                SerializeString(out, value.Keys()[i]);
                out += ':';
                SerializeValue(out, value.ValueAt(i));
            }
            out += '}';
            break;
    }
}

}  // namespace

std::optional<Value> Parse(std::string_view text) {
    // Tolerate a UTF-8 byte order mark from files edited by hand.
    if (text.size() >= 3 && static_cast<unsigned char>(text[0]) == 0xEF &&
        static_cast<unsigned char>(text[1]) == 0xBB && static_cast<unsigned char>(text[2]) == 0xBF) {
        text.remove_prefix(3);
    }
    return Parser(text).ParseDocument();
}

std::string Serialize(const Value& value) {
    std::string out;
    SerializeValue(out, value);
    return out;
}

}  // namespace space::json
