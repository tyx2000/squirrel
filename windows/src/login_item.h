// Purpose: Manages the Open at Login registration (the per-user Run key) and the one-time
// prompt offering it.

#pragma once

#include "common.h"

namespace space {

class Settings;

class LoginItemService {
public:
    LoginItemService();

    void Refresh();
    bool IsEnabled() const { return isEnabled_; }
    const std::wstring& LastMessage() const { return lastMessage_; }
    void ClearMessage();

    void SetEnabled(bool enabled);

    // Offers to enable the login item the first time the app runs, and never asks again.
    void PromptIfNeeded(Settings& settings);

    std::function<void()> onChange;
    // Called before Settings opens, so the floating panel does not cover it.
    std::function<void()> onOpeningSettings;

private:
    bool IsRegistered() const;
    bool IsDisabledInStartupApps() const;
    void Changed();

    bool isEnabled_ = false;
    std::wstring lastMessage_;
};

}  // namespace space
