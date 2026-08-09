#pragma once

#include <set>
#include <vector>

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/rule/Engine.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprlang.hpp>

#include "Hy3Layout.hpp"
#include "TabGroup.hpp"
#include "config/shared/complex/ComplexDataType.hpp"

inline HANDLE PHANDLE = nullptr;

// Suppress algorithm callbacks (newTarget/movedTarget/removeTarget) during
// cross-workspace moves where we manually manage the tree.
inline bool g_suppressInsert = false;

inline std::set<Hy3Layout*> g_hy3Instances;

// Last monitor reported by monitor.focused. Desktop::focusState()->monitor() is
// not yet updated while that event is being delivered, so tab bars recalculated
// from it would compare against the monitor being focused *away* from.
inline PHLMONITORREF g_focusedMonitor;

inline std::vector<WP<Hy3TabGroup>> g_tabGroups;
inline std::vector<UP<Hy3TabGroup>> g_destroyingTabGroups;

// fork: windows whose hy3 tags changed and whose windowrules have not been
// re-evaluated yet. See applyHy3Tag in Hy3Node.cpp for why the recheck cannot
// happen where the tag is set.
inline std::vector<PHLWINDOWREF> g_pendingTagRechecks;

// Runs from the tick listener, i.e. from the event loop with no hy3 tree
// operation on the stack. Deduplicated by window, so a relayout that retags the
// same window several times costs one recheck rather than one per change.
inline void flushHy3TagRechecks() {
	if (g_pendingTagRechecks.empty()) return;

	// taken by value first: a recheck can retag, and appending to the vector
	// being iterated would invalidate the iterator under us
	auto pending = std::move(g_pendingTagRechecks);
	g_pendingTagRechecks.clear();

	// A tag change can affect any rule, and the rule engine offers no per-window
	// entry point - only this. Once per tick regardless of how many windows were
	// retagged, which is what makes it affordable; the old path paid a command
	// parse and a lua evaluation per tag per window instead.
	Desktop::Rule::ruleEngine()->updateAllRules();

	for (auto& ref: pending) {
		auto window = ref.lock();
		if (!window) continue;
		window->updateDecorationValues();
	}
}

inline CHyprSignalListener g_renderListener;
inline CHyprSignalListener g_tickListener;
inline CHyprSignalListener g_windowTitleListener;
inline CHyprSignalListener g_urgentListener;
inline CHyprSignalListener g_monitorFocusListener;

inline Hy3Layout* hy3InstanceForWorkspace(PHLWORKSPACE ws) {
	if (!ws || !ws->m_space || !ws->m_space->algorithm()) return nullptr;
	return dynamic_cast<Hy3Layout*>(ws->m_space->algorithm()->tiledAlgo().get());
}

inline void errorNotif() {
	HyprlandAPI::addNotificationV2(
	    PHANDLE,
	    {
	        {"text", "Something has gone very wrong. Check the log for details."},
	        {"time", (uint64_t) 10000},
	        {"color", CHyprColor(1.0, 0.0, 0.0, 1.0)},
	        {"icon", ICON_ERROR},
	    }
	);
}
