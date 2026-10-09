// Purpose: Persists small preferences (first-run flags and shortcuts) in
// %LOCALAPPDATA%\Space\settings.json, the Windows counterpart of UserDefaults.

#pragma once

#include "json.h"

#include <string>

namespace space {

class Settings {
public:
    void Load();

    bool Flag(const char* key) const;
    void SetFlag(const char* key, bool value);

    // The stored shortcut object, or nullptr if none was saved.
    const json::Value* Shortcuts() const { return root_.Find("shortcuts"); }
    void SetShortcuts(json::Value shortcuts);

private:
    void Save();

    json::Value root_ = json::Value::Object();
    std::wstring path_;
};

}  // namespace space
