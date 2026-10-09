// Purpose: Implements loading and saving of the preferences file.

#include "settings.h"

#include "common.h"

namespace space {

void Settings::Load() {
    std::wstring directory = AppDataDirectory();
    if (directory.empty()) return;
    path_ = directory + L"\\settings.json";

    auto bytes = ReadFileBytes(path_);
    if (!bytes) return;
    auto parsed = json::Parse(std::string_view(reinterpret_cast<const char*>(bytes->data()), bytes->size()));
    if (parsed && parsed->IsObject()) root_ = std::move(*parsed);
}

bool Settings::Flag(const char* key) const {
    const json::Value* value = root_.Find(key);
    return value && value->AsBool();
}

void Settings::SetFlag(const char* key, bool value) {
    root_.Set(key, json::Value::Bool(value));
    Save();
}

void Settings::SetShortcuts(json::Value shortcuts) {
    root_.Set("shortcuts", std::move(shortcuts));
    Save();
}

void Settings::Save() {
    if (path_.empty()) return;
    std::string text = json::Serialize(root_);
    WriteFileAtomic(path_, text.data(), text.size());
}

}  // namespace space
