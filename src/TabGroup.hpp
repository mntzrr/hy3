#pragma once

#include <optional>
#include <utility>
#include <hyprland/src/render/pass/PassElement.hpp>
class Hy3TabGroup;
class Hy3TabBar;
struct Hy3Node;

#include "Types.hpp"

#include <list>
#include <vector>

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/Texture.hpp>

struct Hy3TabGroupWrapper {
	UP<Hy3TabGroup> inner;

	Hy3TabGroupWrapper();
	Hy3TabGroupWrapper(UP<Hy3TabGroup> tg);
	Hy3TabGroupWrapper(Hy3TabGroupWrapper&&);
	Hy3TabGroupWrapper& operator=(Hy3TabGroupWrapper&&);
	~Hy3TabGroupWrapper();

	void release();
	Hy3TabGroupWrapper& operator=(UP<Hy3TabGroup> tg);

	Hy3TabGroup* operator->() { return inner.get(); }
	Hy3TabGroup* get() { return inner.get(); }
	operator bool() const { return inner.get() != nullptr; }
};


struct Hy3TabBarEntry {
	std::string window_title;
	bool destroying = false;
	SP<Render::ITexture> texture;
	PHLANIMVAR<float> active;
	PHLANIMVAR<float> focused;
	PHLANIMVAR<float> urgent;
	PHLANIMVAR<float> active_monitor;
	PHLANIMVAR<float> offset;       // 0.0-1.0 of total bar
	PHLANIMVAR<float> width;        // 0.0-1.0 of total bar
	PHLANIMVAR<float> vertical_pos; // 0.0-1.0, user specified direction
	PHLANIMVAR<float> fade_opacity; // 0.0-1.0
	Hy3TabBar& tab_bar;
	Hy3Node* node; // only used for comparison. do not deref.
	int lastIndex = -1;

	struct {
		float scale = 0.0;
		std::string window_title;
		int full_logical_width = 0;
		// fork: double, not float. renderText computes the width it compares
		// this against as `box.width - padding * 2`, a double - so a float
		// field made the store and the compare disagree at any scale whose
		// product is not float-representable, and an ellipsized title rebuilt
		// its texture every frame. Integer scales round-trip exactly, which is
		// why only fractional ones (1.6, 1.9, ...) were affected.
		double render_width = 0;

		std::string text_font;
		int font_height = 0;

		int texture_x_offset = 0;
		int texture_y_offset = 0;
		int texture_width = 0;
		int texture_height = 0;

		int logical_width = 0;
		int logical_height = 0;
	} last_render;

	Hy3TabBarEntry(Hy3TabBar&, Hy3Node&);
	bool operator==(const Hy3Node&) const;
	bool operator==(const Hy3TabBarEntry&) const;

	void setActive(bool);
	void setFocused(bool);
	void setUrgent(bool);
	void setWindowTitle(std::string);
	void setMonitorActive(bool);
	void beginDestroy();
	void unDestroy();
	bool shouldRemove();
	void render(float scale, CBox& box, float opacity_mul);

private:
	void renderText(float scale, CBox& box, float opacity);
	CHyprColor mergeColors(
	    const CHyprColor& active,
	    const CHyprColor& focused,
	    const CHyprColor& urgent,
	    const CHyprColor& locked,
	    const CHyprColor& active_alt_monitor,
	    const CHyprColor& inactive
	);
};

class Hy3TabBar {
public:
	bool destroy = false;
	bool dirty = true;
	bool damaged = true;
	PHLANIMVAR<float> fade_opacity;
	PHLANIMVAR<float> locked;
	// The monitor this bar resides on
	MONITORID monitor_id = MONITOR_INVALID;

	Hy3TabBar();
	void beginDestroy();
	void damageBox(const Vector2D* position, const Vector2D* size);

	void tick();
	void updateNodeList(std::list<UP<Hy3Node>>& nodes);
	void updateAnimations(bool warp = false);

	std::list<Hy3TabBarEntry> entries;

private:
	// fork: `Vector2D size` and its setSize lived here, written once per frame
	// by renderTabBar and read by nothing since the render path stopped using
	// it. What made the write look load bearing is that findTabBarAt reads
	// `tab_bar.size->value()` - a different member, on Hy3TabGroup.

	// Tab bar entries take a reference to `this`.
	Hy3TabBar(Hy3TabBar&&) = delete;
	Hy3TabBar(const Hy3TabBar&) = delete;
};

// fork: weak, not a raw Hy3TabGroup*. The element is handed to hyprland's
// render pass and drawn later, while the group it names is owned by a node in
// an Hy3Layout tree - Hy3TabGroupWrapper::release() can retire one into
// g_destroyingTabGroups and the tick listener can drop it from there, both
// outside this element's control. A raw pointer made that a call into freed
// memory from inside the compositor's render pass.
//
// Observed with get(), never lock(). Hy3TabGroup is held by a UP and self is a
// weak pointer over it, and hyprutils asserts on locking one of those - there
// is no shared ownership for a SP to take a share of. get() still goes null the
// moment the UP dies, which is the whole of what this needs; pinning the group
// for the duration of the draw is not on offer under unique ownership and is
// not what protects the call.
class Hy3TabPassElement: public IPassElement {
public:
	Hy3TabPassElement(WP<Hy3TabGroup> group): group(std::move(group)) {}

	const char* passName() override { return "Hy3TabPassElement"; }
	std::vector<UP<IPassElement>> draw() override;
	bool needsLiveBlur() override { return false; }
	ePassElementType type() override { return EK_CUSTOM; }
	bool needsPrecomputeBlur() override;
	std::optional<CBox> boundingBox() override;

private:
	WP<Hy3TabGroup> group;
};

class Hy3TabGroup {
public:
	PHLWINDOW target_window = nullptr;
	PHLWORKSPACE workspace = nullptr;
	bool hidden = false;
	Hy3TabBar bar;
	PHLANIMVAR<Vector2D> pos;
	PHLANIMVAR<Vector2D> size;
	WP<Hy3TabGroup> self;

	// Factory: creates a tab group, sets self WP, registers in g_tabGroups.
	static UP<Hy3TabGroup> create(Hy3Node& node);

	// initialize a group with the given node. UB if node is not a group.
	Hy3TabGroup(Hy3Node&);

	// update tab bar with node position and data. UB if node is not a group.
	void updateWithGroup(Hy3Node&, bool warp);
	void tick();
	std::pair<CBox, CBox> getRenderBB() const;
	// render the scaled tab bar on the current monitor.
	void renderTabBar();

private:
	std::vector<PHLWINDOWREF> stencil_windows;
	Vector2D last_workspace_offset;
	Vector2D last_pos;
	Vector2D last_size;

	Hy3TabGroup();

	// moving a Hy3TabGroup will unregister any active animations
	Hy3TabGroup(Hy3TabGroup&&) = delete;

	// UB if node is not a group.
	void updateStencilWindows(Hy3Node&);
};
