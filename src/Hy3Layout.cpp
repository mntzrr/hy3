#include <cstdint>
#include <regex>
#include <optional>
#include <set>

#include <dlfcn.h>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/desktop/state/GlobalWindowController.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/rule/Engine.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/pointer/PointerController.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/PluginSystem.hpp>
#include <hyprland/src/xwayland/XWayland.hpp>
#include <hyprland/src/config/shared/workspace/WorkspaceRuleManager.hpp>
#include <hyprutils/math/Vector2D.hpp>
#include <hyprland/src/config/shared/ConfigErrors.hpp>
#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <ranges>

#include "log.hpp"
#include "Hy3Layout.hpp"
#include "Hy3Node.hpp"
#include "TabGroup.hpp"
#include "globals.hpp"


using namespace Desktop::View;

static CollapsePolicy nodeCollapsePolicy() {
	static const auto node_collapse_policy =
	    CConfigValue<Config::INTEGER>("plugin:hy3:node_collapse_policy");

	switch (*node_collapse_policy) {
	case 0: return CollapsePolicy::SingleNodeGroups;
	case 1: return CollapsePolicy::InvalidOnly;
	default: return CollapsePolicy::EmptySplits;
	}
}

PHLWORKSPACE workspace_for_action(bool allow_fullscreen) {
	auto workspace = Desktop::focusState()->monitor()->m_activeSpecialWorkspace;
	if (!valid(workspace)) workspace = Desktop::focusState()->monitor()->m_activeWorkspace;

	if (!valid(workspace)) return nullptr;
	if (!allow_fullscreen && Fullscreen::controller()->hasFullscreen(workspace)) return nullptr;
	if (!hy3InstanceForWorkspace(workspace)) return nullptr;

	return workspace;
}

std::string operationWorkspaceForName(const std::string& workspace) {
	typedef std::string (*PHYPRSPLIT_GET_WORKSPACE_FN)(const std::string& workspace);

	// Resolved per call, deliberately. Caching this in a static meant a
	// hyprsplit unloaded afterwards left the pointer aimed into a dlclose'd
	// library - the same dangling-call shape that has crashed this compositor
	// before - and caching a *miss* meant a hyprsplit loaded after hy3 never
	// took effect at all, which is the usual load order. This runs on workspace
	// moves, not per frame, and costs a handful of string compares.
	for (auto& p: g_pPluginSystem->getAllPlugins()) {
		if (p->m_name != "hyprsplit") continue;

		auto* transformer =
		    reinterpret_cast<PHYPRSPLIT_GET_WORKSPACE_FN>(dlsym(p->m_handle, "hyprsplitGetWorkspace"));
		if (transformer != nullptr) return transformer(workspace);
		break;
	}

	return workspace;
}

Hy3Node* findTabBarAt(Hy3Node& node, Vector2D pos, Hy3Node** focused_node);

Hy3Layout::Hy3Layout() {
	g_hy3Instances.insert(this);

	m_windowActiveListener = Event::bus()->m_events.window.active.listen(
	    [this](PHLWINDOW window, Desktop::eFocusReason) {
		    if (!window) {
					this->updateGroupBorderColors();
			    return;
				}

		    auto* node = this->getNodeFromWindow(window.get());

		    if (!node) {
					this->updateGroupBorderColors();
					return;
				}

		    this->onWindowFocusChange(window);
	    }
	);

	m_mouseButtonListener = Event::bus()->m_events.input.mouse.button.listen(
	    [this](IPointer::SButtonEvent event, Event::SCallbackInfo& info) {
		    if (event.state != 1 || event.button != 272) return;

		    auto ptr_surface_resource = g_pSeatManager->m_state.pointerFocus.lock();
		    if (!ptr_surface_resource) return;

		    auto ptr_surface = CWLSurface::fromResource(ptr_surface_resource);
		    if (!ptr_surface) return;

		    auto view = ptr_surface->view();
		    auto* window = dynamic_cast<Desktop::View::CWindow*>(view.get());
		    if (!window || window->m_isFloating || Fullscreen::controller()->isFullscreen(window->m_self.lock())) return;

		    auto* node = this->getNodeFromWindow(window);
		    if (!node) return;

		    Hy3Node* focus = nullptr;
		    auto mouse_pos = g_pInputManager->getMouseCoordsInternal();
		    auto* tab_node = findTabBarAt(*this->root, mouse_pos, &focus);
		    if (!tab_node) return;

		    while (focus->is_group() && !focus->as_group().group_focused
		           && focus->as_group().focused_child != nullptr)
			    focus = focus->as_group().focused_child;

		    focus->focus(false, Desktop::FOCUS_REASON_CLICK);
		    g_pInputManager->simulateMouseMovement();
		    this->recalcGeometry();

		    info.cancelled = true;
	    }
	);
}

// fork: release everything that can call back into this library.
//
// An instance is owned by hyprland, not by the plugin, so it can outlive
// PLUGIN_EXIT. Anything still registered at that point - the event
// subscriptions below, and the animated variables inside every tab group, whose
// update callbacks are lambdas compiled into this .so - would be invoked
// through an unmapped address once the library is dlclose'd.
//
// Safe to call more than once, and safe to call while the instance stays alive:
// it leaves an empty layout behind rather than a half torn down one.
void Hy3Layout::shutdown() {
	// first, so nothing can re-enter the plugin while the tree is going away
	m_windowActiveListener.reset();
	m_mouseButtonListener.reset();

	if (this->root) {
		for (auto& window: this->root->windows()) {
			window.setHidden(false);
		}
	}

	// destroys the node tree, and with it every tab group and animated variable
	this->root.reset();
}

Hy3Layout::~Hy3Layout() {
	this->shutdown();

	g_hy3Instances.erase(this);
}

PHLWORKSPACE Hy3Layout::workspace() {
	auto algo = m_parent.lock();
	if (!algo) return nullptr;
	auto space = algo->space();
	if (!space) return nullptr;
	return space->workspace();
}

PHLMONITORREF Hy3Layout::monitor() {
	auto ws = workspace();
	if (!ws) return nullptr;
	return ws->m_monitor;
}

// ITiledAlgorithm overrides

void Hy3Layout::newTarget(SP<Layout::ITarget> target) {
	if (g_suppressInsert) return;
	auto window = target->window();
	if (!window) return;
	hy3_log(
	    LOG,
	    "newTarget called with window {:x} (monitor: {}, workspace: {})",
	    (uintptr_t) window.get(),
	    window->monitorID(),
	    target->workspace() ? target->workspace()->m_id : -1
	);

	auto* existing = this->getNodeFromTarget(target);
	if (existing != nullptr) {
		hy3_log(
		    ERR,
		    "newTarget called with a target ({:x}) that is already tiled (node: {:x})",
		    (uintptr_t) window.get(),
		    (uintptr_t) existing
		);
		return;
	}

	auto node = Hy3Node::create(target);

	this->insertNode(std::move(node));
}

Hy3Node* Hy3Layout::insertNode(UP<Hy3Node> node_up, std::optional<Vector2D> focalPoint) {
	if (node_up->parent != nullptr) {
		hy3_log(
		    ERR,
		    "insertNode called for node {:x} which already has a parent ({:x})",
		    (uintptr_t) node_up.get(),
		    (uintptr_t) node_up->parent.get()
		);
		return nullptr;
	}

	auto ws = this->workspace();
	if (!valid(ws)) {
		hy3_log(
		    ERR,
		    "insertNode called for node {:x} with invalid workspace id {}",
		    (uintptr_t) node_up.get(),
		    ws ? ws->m_id : -1
		);
		return nullptr;
	}

	node_up->size_ratio = 1.0;

	auto& monitor = ws->m_monitor;

	Hy3Node* opening_into;
	Hy3Node* opening_after = nullptr;

	auto* rootNode = this->getWorkspaceRootGroup(ws.get());

	if (rootNode != nullptr) {
		if (focalPoint) {
			auto window_at_point =
					Desktop::viewState()->hitTest().windowAt(*focalPoint, RESERVED_EXTENTS | INPUT_EXTENTS);

			if (window_at_point && window_at_point->m_workspace == ws) {
				opening_after = this->getNodeFromWindow(window_at_point.get());
			}
		}

		if (!opening_after) opening_after = &rootNode->getFocusedNode();
		opening_after = &opening_after->getPlacementActor();

		// opening_after->parent cannot be nullptr
		if (opening_after == rootNode) {
			opening_after->wrap(Hy3GroupLayout::SplitH, GroupEphemeralityOption::Standard);
		}

		opening_into = opening_after->parent.get();
	} else {
		static const auto tab_first_window =
		    CConfigValue<Config::INTEGER>("plugin:hy3:tab_first_window");

		// Use space work area if available, fall back to monitor
		CBox wa_box(monitor->m_position, monitor->m_size);
		auto algo = m_parent.lock();
		if (algo) {
			auto space = algo->space();
			if (space) wa_box = space->workArea();
		}

		// getWorkspaceRootGroup() returns null both when there is no root and
		// when the root exists but is empty, so reaching here does not mean a
		// root has to be built. Replacing a live one discards it - along with
		// anything hanging off it - to put back an equivalent.
		if (!this->root) {
			auto rootUp = makeUnique<Hy3RootNode>(this);
			rootUp->self = WP<Hy3Node>(rootUp);
			this->root = std::move(rootUp);
		}

		UP<Hy3Node> rootGroup;
		if (*tab_first_window) {
			rootGroup = Hy3Node::create(Hy3GroupLayout::Tabbed);
		} else {
			auto split_layout =
					wa_box.height > wa_box.width ? Hy3GroupLayout::SplitV : Hy3GroupLayout::SplitH;
			rootGroup = Hy3Node::create(split_layout);
		}

		opening_into = rootGroup.get();
		this->root->as_group().insertChild(std::move(rootGroup));
	}

	if (opening_into->is_target()) {
		hy3_log(ERR, "opening_into node ({:x}) was not a group node", (uintptr_t) opening_into);
		errorNotif();
		return nullptr;
	}

	{
		// clang-format off
		static const auto at_enable = CConfigValue<Config::INTEGER>("plugin:hy3:autotile:enable");
		static const auto at_ephemeral = CConfigValue<Config::INTEGER>("plugin:hy3:autotile:ephemeral_groups");
		static const auto at_trigger_width = CConfigValue<Config::INTEGER>("plugin:hy3:autotile:trigger_width");
		static const auto at_trigger_height = CConfigValue<Config::INTEGER>("plugin:hy3:autotile:trigger_height");
		// clang-format on

		this->updateAutotileWorkspaces();

		auto& target_group = opening_into->as_group();
		if (*at_enable && opening_after != nullptr && target_group.children.size() > 1
		    && target_group.isSplit()
		    && this->shouldAutotileWorkspace(ws.get()))
		{
			auto is_horizontal = target_group.layout == Hy3GroupLayout::SplitH;
			auto trigger = is_horizontal ? *at_trigger_width : *at_trigger_height;
			auto target_size = is_horizontal ? opening_into->visualBox.w : opening_into->visualBox.h;
			auto size_after_addition = target_size / (target_group.children.size() + 1);

			if (trigger >= 0 && (trigger == 0 || size_after_addition < trigger)) {
				opening_after->wrap(
				    is_horizontal ? Hy3GroupLayout::SplitV : Hy3GroupLayout::SplitH,
				    *at_ephemeral ? GroupEphemeralityOption::Ephemeral : GroupEphemeralityOption::Standard
				);
				opening_into = opening_after->parent.get();
			}
		}
	}

	// For mouse drops, determine if we should insert before or after the target node
	if (focalPoint && opening_after) {
		auto& parentGroup = opening_into->as_group();
		bool insert_before = false;

		if (parentGroup.layout == Hy3GroupLayout::SplitH) {
			insert_before = focalPoint->x < opening_after->visualBox.x + opening_after->visualBox.w * 0.5;
		} else if (parentGroup.layout == Hy3GroupLayout::SplitV) {
			insert_before = focalPoint->y < opening_after->visualBox.y + opening_after->visualBox.h * 0.5;
		}

		if (insert_before) {
			auto iter = parentGroup.findChild(*opening_after);
			if (iter != parentGroup.children.begin()) {
				opening_after = std::prev(iter)->get();
			} else {
				opening_after = nullptr;
			}
		}
	}

	auto* node = node_up.get();

	{
		auto& group = opening_into->as_group();
		if (opening_after == nullptr) {
			group.insertChild(group.children.begin(), std::move(node_up));
		} else {
			auto iter = group.findChild(*opening_after);
			group.insertChild(std::next(iter), std::move(node_up));
		}
	}

	hy3_log(
	    LOG,
	    "tiled node {:x} inserted {} node {:x} in node {:x}",
	    (uintptr_t) node,
	    opening_after ? "after" : "at beginning of",
	    (uintptr_t) opening_after,
	    (uintptr_t) opening_into
	);

	node->markFocused();
	this->recalcGeometry();
	this->updateGroupBorderColors();

	return node;
}

void Hy3Layout::movedTarget(SP<Layout::ITarget> target, std::optional<Vector2D> focalPoint) {
	if (g_suppressInsert) return;

	// Use mouse position as focal point when none provided (e.g. DnD drop)
	if (!focalPoint) focalPoint = g_pInputManager->getMouseCoordsInternal();

	this->insertNode(Hy3Node::create(target), focalPoint);
}

void Hy3Layout::removeTarget(SP<Layout::ITarget> target) {
	if (g_suppressInsert) return;

	auto* node = this->getNodeFromTarget(target);
	if (node == nullptr) return;

	// fork: as_window() threw for an expired target and returned null for a window
	// already torn down; both were then used unconditionally. This runs from
	// CWindow::unmapWindow, so either one took the compositor down. The node still
	// has to leave the tree in that case - only the window-side cleanup is skipped.
	auto window = node->try_window();

	hy3_log(
	    LOG,
	    "removing target (window {:x} as node {:x}) from node {:x}",
	    (uintptr_t) window.get(),
	    (uintptr_t) node,
	    (uintptr_t) node->parent.get()
	);

	if (window) {
		window->m_ruleApplicator
		    ->resetProps(Desktop::Rule::RULE_PROP_ALL, Desktop::Types::PRIORITY_LAYOUT);
	}

	auto* parent_node = node->parent.get();
	// Extracted UP drops — node is destroyed.
	parent_node->extractAndMerge(*node, nullptr, CollapsePolicy::InvalidOnly);
	this->recalcGeometry();

	this->updateGroupBorderColors();
}

void Hy3Layout::onWindowFocusChange(PHLWINDOW window) {
	auto* node = this->getNodeFromWindow(window.get());
	if (node == nullptr) return;

	hy3_log(
	    TRACE,
	    "changing window focus to window {:x} as node {:x}",
	    (uintptr_t) window.get(),
	    (uintptr_t) node
	);

	node->markFocused();
	this->recalcGeometry();

	this->updateGroupBorderColors();
}

void Hy3Layout::updateGroupBorderColors() {
	if (!this->root) return;
	static auto active_color = CConfigValue<Config::IComplexConfigValue>("general:col.active_border");
	auto* const active_color_data = sc<Config::CGradientValueData*>(active_color.ptr());

	for (auto& w: this->root->windows()) {
		if (this->shouldRenderSelected(&w)) {
			w.m_ruleApplicator->inactiveBorderColor().set(*active_color_data, Desktop::Types::PRIORITY_LAYOUT);
		} else {
			w.m_ruleApplicator->inactiveBorderColor().unset(Desktop::Types::PRIORITY_LAYOUT);
		}

		w.updateDecorationValues();
	}
}

void Hy3Layout::recalculate(Layout::eRecalculateReason) { this->recalcGeometry(); }

void Hy3Layout::recalcGeometry(bool no_animation) {
	auto algo = m_parent.lock();
	if (!algo) return;
	auto space = algo->space();
	if (!space) return;
	auto workspace = space->workspace();
	if (!workspace) return;

	hy3_log(LOG, "recalculating workspace {}", workspace->m_id);

	auto ma = workspace->m_monitor->logicalBoxMinusReserved();
	auto wa = space->workArea();

	if (this->root) {
	this->root->visualBox = wa;
	this->root->recalcSizePosRecursive(CBox{
	    wa.x - ma.x,
	    wa.y - ma.y,
	    (ma.x + ma.w) - (wa.x + wa.w),
	    (ma.y + ma.h) - (wa.y + wa.h),
	}, no_animation);
	}
}

ShiftDirection reverse(ShiftDirection direction) {
	switch (direction) {
	case ShiftDirection::Left: return ShiftDirection::Right;
	case ShiftDirection::Right: return ShiftDirection::Left;
	case ShiftDirection::Up: return ShiftDirection::Down;
	case ShiftDirection::Down: return ShiftDirection::Up;
	default: return direction;
	}
}

void Hy3Layout::resizeTarget(const Vector2D& delta, SP<Layout::ITarget> target, Layout::eRectCorner corner) {
	auto* node = target ? this->getNodeFromTarget(target) : nullptr;
	if (node == nullptr) return;

	// fork: the valid() check below was already here, but as_window() threw before
	// reaching it whenever the target itself had expired.
	auto window = node->try_window();
	if (!valid(window)) return;

	node = &node->getExpandActor();

	// Compare against work area since node position/size is the visible area
	CBox workArea = {};
	auto algo = this->m_parent.lock();
	if (algo) {
		auto space = algo->space();
		if (space) workArea = space->workArea();
	}

	const bool display_left = STICKS(node->visualBox.x, workArea.x);
	const bool display_right = STICKS(node->visualBox.x + node->visualBox.w, workArea.x + workArea.w);
	const bool display_top = STICKS(node->visualBox.y, workArea.y);
	const bool display_bottom = STICKS(node->visualBox.y + node->visualBox.h, workArea.y + workArea.h);

	Vector2D resize_delta = delta;
	bool node_is_root =
	    node->is_root()
	    || (node->is_target() && node->parent->is_root());

	if (node_is_root) {
		if (display_left && display_right) resize_delta.x = 0;
		if (display_top && display_bottom) resize_delta.y = 0;
	}

	if (resize_delta.x == 0 && resize_delta.y == 0) return;

	ShiftDirection target_edge_x;
	ShiftDirection target_edge_y;

	if (corner == Layout::CORNER_NONE) {
		target_edge_x = display_right ? ShiftDirection::Left : ShiftDirection::Right;
		target_edge_y = display_bottom ? ShiftDirection::Up : ShiftDirection::Down;

		if (target_edge_x == ShiftDirection::Left) resize_delta.x = -resize_delta.x;
		if (target_edge_y == ShiftDirection::Up) resize_delta.y = -resize_delta.y;
	} else {
		target_edge_x = corner & Layout::CORNER_LEFT ? ShiftDirection::Left : ShiftDirection::Right;
		target_edge_y = corner & Layout::CORNER_TOP ? ShiftDirection::Up : ShiftDirection::Down;
	}

	auto horizontal_neighbor = node->findNeighbor(target_edge_x);
	auto vertical_neighbor = node->findNeighbor(target_edge_y);

	static const auto animate = CConfigValue<Config::INTEGER>("misc:animate_manual_resizes");

	if (horizontal_neighbor) {
		horizontal_neighbor->resize(reverse(target_edge_x), resize_delta.x, *animate == 0);
	}

	if (vertical_neighbor) {
		vertical_neighbor->resize(reverse(target_edge_y), resize_delta.y, *animate == 0);
	}
}

void Hy3Layout::swapTargets(SP<Layout::ITarget> a, SP<Layout::ITarget> b) {
	// todo
}

void Hy3Layout::moveTargetInDirection(SP<Layout::ITarget> t, Math::eDirection dir, bool silent) {
	auto* node = t ? this->getNodeFromTarget(t) : nullptr;
	if (node == nullptr) return;

	ShiftDirection shift;
	switch (dir) {
	case Math::DIRECTION_LEFT: shift = ShiftDirection::Left; break;
	case Math::DIRECTION_RIGHT: shift = ShiftDirection::Right; break;
	case Math::DIRECTION_UP: shift = ShiftDirection::Up; break;
	case Math::DIRECTION_DOWN: shift = ShiftDirection::Down; break;
	default: return;
	}

	this->shiftNode(*node, shift, false, false);
}

Config::ErrorResult Hy3Layout::layoutMsg(const std::string_view& sv) {
	std::string content(sv);

	if (content == "togglesplit") {
		auto window = Desktop::focusState()->window();
		if (!window) return {};
		auto* node = this->getNodeFromWindow(window.get());
		if (node != nullptr) {
			node->assertNotRoot();
			auto& layout = node->parent->as_group().layout;

			switch (layout) {
			case Hy3GroupLayout::SplitH:
				layout = Hy3GroupLayout::SplitV;
				this->recalcGeometry();
				break;
			case Hy3GroupLayout::SplitV:
				layout = Hy3GroupLayout::SplitH;
				this->recalcGeometry();
				break;
			case Hy3GroupLayout::Root: break;
			case Hy3GroupLayout::Tabbed: break;
			}
		}
	}

	return {};
}

std::optional<Vector2D> Hy3Layout::predictSizeForNewTarget() {
	return std::nullopt;
}

SP<Layout::ITarget> Hy3Layout::getNextCandidate(SP<Layout::ITarget> old) {
	auto window = old ? old->window() : nullptr;
	if (!window) return nullptr;

	auto candidate = this->findTiledWindowCandidate(window.get());
	if (!candidate) return nullptr;

	auto* node = this->getNodeFromWindow(candidate.get());
	if (!node) return nullptr;
	return node->try_target(); // fork: no candidate is better than a throw
}

PHLWINDOW Hy3Layout::findTiledWindowCandidate(const CWindow* from) {
	auto* node = this->getWorkspaceFocusedNode(from->m_workspace.get(), true);
	if (node != nullptr && node->is_target()) {
		// fork: this is the focus-successor search run while a window is closing,
		// so meeting an expired target here is ordinary, not exceptional
		if (auto window = node->try_window()) return window;
	}

	return PHLWINDOW();
}

PHLWINDOW Hy3Layout::findFloatingWindowCandidate(const CWindow* from) {
	// return the first floating window on the same workspace that has not asked not to be focused
	for (const auto& w: Desktop::windowState()->windows() | std::views::reverse) {
		if (w->m_isMapped && !w->isHidden() && w->m_isFloating && !w->isX11OverrideRedirect()
		    && w->m_workspace == from->m_workspace && !w->m_X11ShouldntFocus
		    && !w->m_ruleApplicator->noFocus().valueOrDefault() && w.get() != from)
		{
			return w;
		}
	}

	return nullptr;
}

void Hy3Layout::makeGroupOnWorkspace(
    const CWorkspace* workspace,
    Hy3GroupLayout layout,
    GroupEphemeralityOption ephemeral,
    bool toggle
) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node = &node->getPlacementActor();

	if (toggle) {
		auto* parent = node->parent.get();
		auto& group = parent->as_group();

		if (group.children.size() == 1 && group.layout == layout) {
			auto* collapsed = parent->collapseParents(CollapsePolicy::SingleNodeGroups);

			// fork: a group hanging directly off the root whose only child is a
			// window is never collapsed. shouldCollapseNode refuses it outright,
			// before it ever looks at the policy, so that a workspace always
			// keeps a group as its top level container.
			//
			// collapseParents then hands the group straight back, and toggling
			// off is a no-op: on a workspace holding a single window the tab bar
			// and the space it insets stay put, and no number of further presses
			// changes anything. Upstream #192.
			//
			// The container has to survive, but its layout does not - dropping it
			// back to the split it came from is what toggling off means for it,
			// and leaves exactly the picture collapsing would have.
			if (collapsed == parent && parent->is_root_group() && group.isTab()) {
				this->untabGroupOn(*node);
				return;
			}

			if (collapsed && !collapsed->is_root()) {
				collapsed->parent->updateTabBarRecursive();
				this->recalcGeometry();
			}

			return;
		}
	}

	this->makeGroupOn(*node, layout, ephemeral);
}

void Hy3Layout::makeOppositeGroupOnWorkspace(
    const CWorkspace* workspace,
    GroupEphemeralityOption ephemeral
) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node = &node->getPlacementActor();
	this->makeOppositeGroupOn(*node, ephemeral);
}

void Hy3Layout::changeGroupOnWorkspace(const CWorkspace* workspace, Hy3GroupLayout layout) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node = &node->getPlacementActor();

	this->changeGroupOn(*node, layout);
}

void Hy3Layout::untabGroupOnWorkspace(const CWorkspace* workspace) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node = &node->getPlacementActor();

	this->untabGroupOn(*node);
}

void Hy3Layout::toggleTabGroupOnWorkspace(const CWorkspace* workspace) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node = &node->getPlacementActor();

	this->toggleTabGroupOn(*node);
}

void Hy3Layout::changeGroupToOppositeOnWorkspace(const CWorkspace* workspace) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node = &node->getPlacementActor();

	this->changeGroupToOppositeOn(*node);
}

void Hy3Layout::changeGroupEphemeralityOnWorkspace(const CWorkspace* workspace, bool ephemeral) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node = &node->getPlacementActor();

	this->changeGroupEphemeralityOn(*node, ephemeral);
}

void Hy3Layout::makeGroupOn(
    Hy3Node& node,
    Hy3GroupLayout layout,
    GroupEphemeralityOption ephemeral
) {
	node.assertNotRoot();

	hy3_log(LOG, "mkGrp on {:x} b4\n{}", (uintptr_t)&node, debugNodes());

	node.wrap(layout, ephemeral);
	node.parent->collapseParents(CollapsePolicy::InvalidOnly);
	this->recalcGeometry();
}

void Hy3Layout::makeOppositeGroupOn(Hy3Node& node, GroupEphemeralityOption ephemeral) {
	node.assertNotRoot();

	auto& group = node.parent->as_group();
	auto layout =
	    group.layout == Hy3GroupLayout::SplitH ? Hy3GroupLayout::SplitV : Hy3GroupLayout::SplitH;

	if (group.children.size() == 1) {
		group.setLayout(layout);
		group.setEphemeral(ephemeral);
		this->recalcGeometry();
		return;
	}

	node.wrap(layout, ephemeral);
}

void Hy3Layout::changeGroupOn(Hy3Node& node, Hy3GroupLayout layout) {
	node.assertNotRoot();
	auto& group = node.parent->as_group();
	group.setLayout(layout);
	node.parent->updateTabBarRecursive();
	this->recalcGeometry();
}

void Hy3Layout::untabGroupOn(Hy3Node& node) {
	node.assertNotRoot();
	auto& group = node.parent->as_group();
	if (!group.isTab()) return;

	changeGroupOn(node, group.previous_nontab_layout);
}

void Hy3Layout::toggleTabGroupOn(Hy3Node& node) {
	node.assertNotRoot();
	auto& group = node.parent->as_group();
	if (!group.isTab()) changeGroupOn(node, Hy3GroupLayout::Tabbed);
	else changeGroupOn(node, group.previous_nontab_layout);
}

void Hy3Layout::changeGroupToOppositeOn(Hy3Node& node) {
	node.assertNotRoot();
	auto& group = node.parent->as_group();

	if (group.isTab()) {
		group.setLayout(group.previous_nontab_layout);
	} else {
		group.setLayout(
		    group.layout == Hy3GroupLayout::SplitH ? Hy3GroupLayout::SplitV : Hy3GroupLayout::SplitH
		);
	}

	this->recalcGeometry();
}

void Hy3Layout::changeGroupEphemeralityOn(Hy3Node& node, bool ephemeral) {
	node.assertNotRoot();
	auto& group = node.parent->as_group();
	group.setEphemeral(
	    ephemeral ? GroupEphemeralityOption::ForceEphemeral : GroupEphemeralityOption::Standard
	);
}

void Hy3Layout::shiftNode(
    Hy3Node& node,
    ShiftDirection direction,
    bool once,
    bool visible,
    bool monitor_fallthrough,
    bool warp
) {
	this->shiftOrGetFocus(node, direction, true, once, visible, monitor_fallthrough, warp);
}

void Hy3Layout::shiftWindow(
    const CWorkspace* workspace,
    ShiftDirection direction,
    bool once,
    bool visible,
    bool monitor_fallthrough,
    bool warp
) {
	// fork: the config flag turns the fallthrough on for every movewindow, the
	// argument turns it on for a single invocation.
	static const auto fallthrough_default =
	    CConfigValue<Config::INTEGER>("plugin:hy3:movewindow_monitor_fallthrough");

	// fork: a floating window is not in the hy3 tree, so getWorkspaceFocusedNode
	// hands back whatever tiled node last had focus and upstream moves *that* -
	// a window the user is not looking at, and cannot see move if the floating
	// one covers it (upstream #223). Never do that.
	//
	// movewindow_floating then moves the floating window itself, so one bind
	// covers both layers as it does in i3 and sway (upstream #85, #226). The
	// move is handed to hyprland's floating algorithm, which snaps the window
	// to the work area edge in that direction - the same thing hyprland's own
	// movewindow does, rather than a second set of semantics to learn.
	//
	// Once it is against that edge the monitor fallthrough takes over, exactly
	// as it does for a node at the edge of the tree. That is also the path a
	// floating window took before this branch existed - through the tiled
	// node's shiftMonitor and into moveNodeToWorkspace's floating case - so
	// with movewindow_floating off the fallthrough behaves as it always has.
	static const auto floating_moves = CConfigValue<Config::INTEGER>("plugin:hy3:movewindow_floating");

	auto current_window = Desktop::focusState()->window();
	if (current_window != nullptr && current_window->m_isFloating) {
		auto target = current_window->layoutTarget();
		auto space = target != nullptr ? target->space() : nullptr;

		if (*floating_moves && space != nullptr) {
			auto before = target->position().pos();
			space->moveTargetInDirection(target, shiftToMathDirection(direction), false);
			if (target->position().pos() != before) return;
		}

		if (monitor_fallthrough || *fallthrough_default) {
			this->moveToMonitor(
			    current_window->m_workspace.get(),
			    this->monitorInDirection(direction),
			    true,
			    warp
			);
		}

		return;
	}

	auto* node = this->getWorkspaceFocusedNode(workspace);
	if (node == nullptr) return;

	this->shiftNode(
	    *node,
	    direction,
	    once,
	    visible,
	    monitor_fallthrough || *fallthrough_default,
	    warp
	);
}

void Hy3Layout::shiftFocus(
    const CWorkspace* workspace,
    ShiftDirection direction,
    bool visible,
    bool warp
) {
	auto current_window = Desktop::focusState()->window();

	if (current_window != nullptr) {
		if (Fullscreen::controller()->hasFullscreen(current_window->m_workspace)) {
			return;
		}

		if (current_window->m_isFloating) {
			auto next_window = Desktop::windowState()->query().inDirection(
			    current_window,
			    shiftToMathDirection(direction)
			);

			if (next_window != nullptr) {
				g_pInputManager->unconstrainMouse();
				Desktop::focusState()->fullWindowFocus(next_window, Desktop::FOCUS_REASON_KEYBIND);
				// layoutBox rather than m_reportedPosition, which is stale here
				// for the same reason as in Hy3Node::focus. this window is
				// floating, so it has no node to take a visualBox from.
				if (warp) {
					auto box = next_window->layoutBox();
					Hy3Layout::warpCursorToBox(box.pos(), box.size());
				}
			}
			return;
		}
	}

	auto* node = this->getWorkspaceFocusedNode(workspace);
	if (node == nullptr) {
		focusMonitor(direction, warp);
		return;
	}

	auto* target = this->shiftOrGetFocus(*node, direction, false, false, visible, false, warp);

	if (target != nullptr) {
		if (warp) {
			// don't warp for nodes in the same tab
			warp = node->parent != target->parent
			    || !node->parent->as_group().isTab();
		}

		target->focus(warp, Desktop::FOCUS_REASON_KEYBIND);
		this->recalcGeometry();
	}
}

// fork: true if the user is currently focused on a window living on a special
// (scratchpad) workspace. deliberately keyed off the focused window rather than
// the layout's workspace - a visible-but-unfocused scratchpad should not stop
// directional focus from leaving the monitor.
static bool focusedOnSpecialWorkspace() {
	auto window = Desktop::focusState()->window();
	if (window == nullptr || !valid(window->m_workspace)) return false;
	return window->m_workspace->m_isSpecialWorkspace;
}

Hy3Node* Hy3Layout::focusMonitor(ShiftDirection direction, bool warp) {
	// fork: with special_focus_trap enabled, directional focus never escapes a
	// scratchpad to another monitor - it simply stays put.
	static const auto special_focus_trap =
	    CConfigValue<Config::INTEGER>("plugin:hy3:special_focus_trap");

	if (*special_focus_trap && focusedOnSpecialWorkspace()) return nullptr;

	auto next_monitor = State::monitorState()
													->query()
													.relativeTo(this->monitor().lock())
													.inDirection(shiftToMathDirection(direction))
													.run();

	if (next_monitor) {
		bool found = false;
		Desktop::focusState()->rawMonitorFocus(next_monitor);
		auto next_workspace = next_monitor->m_activeWorkspace;

		if (next_workspace) {
			auto target_window = next_workspace->getLastFocusedWindow();
			if (target_window) {
				found = true;

				if (auto* hy3 = hy3InstanceForWorkspace(next_workspace)) {
					auto found_node = hy3->getNodeFromWindow(target_window.get());
					if (found_node) {
						// fork: honour the caller's warp preference. This was
						// hardcoded true, so `hy3:movefocus <dir> nowarp` warped
						// the cursor anyway whenever focus crossed a monitor.
						found_node->focus(warp, Desktop::FOCUS_REASON_KEYBIND);
						return found_node;
					}
				} else {
					Desktop::focusState()->fullWindowFocus(target_window, Desktop::FOCUS_REASON_KEYBIND);
					return nullptr;
				}
			}
		}

		// nothing focusable there: centring the cursor is the only thing that
		// makes the monitor focus visible, but it is still a warp, so it obeys
		// the same preference.
		if (!found && warp) {
			Hy3Layout::warpCursorWithFocus(next_monitor->m_position + next_monitor->m_size / 2);
		}
	}
	return nullptr;
}

PHLMONITOR Hy3Layout::monitorInDirection(ShiftDirection direction) {
	return State::monitorState()
	    ->query()
	    .relativeTo(this->monitor().lock())
	    .inDirection(shiftToMathDirection(direction))
	    .run();
}

// fork: resolve a monitor argument accepting hy3 shift directions (l/r/u/d),
// a relative offset (+n / -n, wrapping around the enabled monitors), and
// hyprland's own selectors (<name>, desc:<description>, <id>).
PHLMONITOR Hy3Layout::monitorFromSelector(const std::string& selector) {
	if (selector.empty()) return nullptr;

	if (selector == "l" || selector == "left") return this->monitorInDirection(ShiftDirection::Left);
	if (selector == "r" || selector == "right") return this->monitorInDirection(ShiftDirection::Right);
	if (selector == "u" || selector == "up") return this->monitorInDirection(ShiftDirection::Up);
	if (selector == "d" || selector == "down") return this->monitorInDirection(ShiftDirection::Down);

	// CMonitorQuery::selector does not understand relative offsets, so cycle
	// through the monitor list by hand.
	if (selector[0] == '+' || selector[0] == '-') {
		int offset = 0;

		try {
			offset = std::stoi(selector);
		} catch (const std::exception&) {
			return nullptr;
		}

		auto& monitors = State::monitorState()->monitors();
		if (monitors.empty()) return nullptr;

		auto current = this->monitor().lock();
		auto iter = std::ranges::find(monitors, current);
		if (iter == monitors.end()) return nullptr;

		auto count = static_cast<int>(monitors.size());
		auto index = ((static_cast<int>(iter - monitors.begin()) + offset) % count + count) % count;

		return monitors[index];
	}

	return State::monitorState()->query().selector(selector).run();
}

// fork: give keyboard focus back to whatever was last focused on a monitor.
// rawMonitorFocus alone only moves the *monitor* focus, leaving the window that
// was just moved away still focused on the other screen.
static void refocusMonitor(PHLMONITOR monitor) {
	if (!monitor) return;

	Desktop::focusState()->rawMonitorFocus(monitor);

	auto workspace = monitor->m_activeSpecialWorkspace;
	if (!valid(workspace)) workspace = monitor->m_activeWorkspace;
	if (!valid(workspace)) return;

	// moveNodeToWorkspace already refocused this workspace's remaining node on
	// the nofollow path, so only what it cannot serve is left here: a workspace
	// with nothing in the hy3 tree, holding floating windows only.
	if (auto* hy3 = hy3InstanceForWorkspace(workspace)) {
		if (hy3->getWorkspaceFocusedNode(workspace.get()) != nullptr) return;
	}

	// the window that was just moved away is still this workspace's last
	// focused one, and focusing it would chase it onto the other screen. it now
	// reports the destination workspace, so the check below rejects it.
	auto target_window = workspace->getLastFocusedWindow();
	if (!target_window || target_window->m_workspace != workspace) return;

	Desktop::focusState()->fullWindowFocus(target_window, Desktop::FOCUS_REASON_KEYBIND);
}

bool Hy3Layout::shiftMonitor(Hy3Node& node, ShiftDirection direction, bool follow, bool warp) {
	return this->moveToMonitor(
	    node.layoutWorkspace().get(),
	    this->monitorInDirection(direction),
	    follow,
	    warp
	);
}

// fork: move the focused node - a window, or a whole group when focus is
// raised - into the active workspace of another monitor, keeping it intact in
// the destination hy3 tree. unlike hyprland's own monitor move, `follow` is
// honoured: with it unset focus is left where the user put it.
bool Hy3Layout::moveToMonitor(CWorkspace* origin, PHLMONITOR target, bool follow, bool warp) {
	if (!target || origin == nullptr) return false;

	auto origin_monitor = this->monitor().lock();
	if (origin_monitor == target) return false;

	auto next_workspace = target->m_activeWorkspace;
	if (!valid(next_workspace)) return false;

	if (follow) Desktop::focusState()->rawMonitorFocus(target);

	this->moveNodeToWorkspace(origin, next_workspace->m_name, follow, warp);

	// the moved node keeps keyboard focus even though it is now on another
	// screen, so hand focus back to the monitor it left.
	if (!follow) refocusMonitor(origin_monitor);

	return true;
}

bool Hy3Layout::moveNodeToMonitor(
    CWorkspace* origin,
    const std::string& selector,
    bool follow,
    bool warp
) {
	return this->moveToMonitor(origin, this->monitorFromSelector(selector), follow, warp);
}

// fork: scratchpad aware floating toggle. a window sitting on a special
// workspace is unmounted onto `unmount_workspace` - or, when that is empty, the
// workspace visible underneath it - otherwise floating is toggled as usual.
void Hy3Layout::toggleFloating(CWorkspace* workspace, const std::string& unmount_workspace, bool warp) {
	auto window = Desktop::focusState()->window();

	// prefer the focused window's workspace: a visible but unfocused scratchpad
	// must not hijack the action.
	auto* ws = window != nullptr && valid(window->m_workspace) ? window->m_workspace.get() : workspace;
	if (ws == nullptr) return;

	if (ws->m_isSpecialWorkspace) {
		auto target = unmount_workspace;

		if (target.empty()) {
			// a monitor's active workspace is never the special one - that is
			// tracked separately - so this is the workspace underneath.
			auto monitor = ws->m_monitor;
			if (!monitor || !valid(monitor->m_activeWorkspace)) return;
			target = monitor->m_activeWorkspace->m_name;
		}

		this->moveNodeToWorkspace(ws, target, true, warp);
		return;
	}

	if (window == nullptr || !ws->m_space) return;
	ws->m_space->toggleTargetFloating(window->layoutTarget());
}

void Hy3Layout::toggleFocusLayer(const CWorkspace* workspace, bool warp) {
	auto current_window = Desktop::focusState()->window();
	if (!current_window) return;

	PHLWINDOW target;
	if (current_window->m_isFloating) {
		target = this->findTiledWindowCandidate(current_window.get());
	} else {
		target = this->findFloatingWindowCandidate(current_window.get());
	}

	if (!target) return;

	Desktop::focusState()->fullWindowFocus(target, Desktop::FOCUS_REASON_KEYBIND);

	if (warp) {
		Hy3Layout::warpCursorWithFocus(target->middle());
	}
}

void Hy3Layout::warpCursor() {
	auto current_window = Desktop::focusState()->window();

	if (current_window != nullptr) {
		Hy3Layout::warpCursorWithFocus(current_window->middle(), true);
	} else {
		auto* node =
		    this->getWorkspaceFocusedNode(Desktop::focusState()->monitor()->m_activeWorkspace.get());

		if (node != nullptr) {
			Hy3Layout::warpCursorWithFocus(node->visualBox.pos() + node->visualBox.size() / 2);
		}
	}
}

static void updateTreeTabBars(Hy3Node& node) {
	node.updateTabBar();
	if (node.is_group()) {
		for (auto& child: node.as_group().children) {
			updateTreeTabBars(*child);
		}
	}
}


void Hy3Layout::moveNodeToWorkspace(
    CWorkspace* origin,
    std::string wsname,
    bool follow,
    bool warp
) {
	auto target = getWorkspaceIDNameFromString(operationWorkspaceForName(wsname));

	if (target.id == WORKSPACE_INVALID) {
		hy3_log(ERR, "moveNodeToWorkspace called with invalid workspace {}", wsname);
		return;
	}

	auto workspace = State::workspaceState()->query().id(target.id).run();

	if (origin == workspace.get()) return;

	auto* node = this->getWorkspaceFocusedNode(origin);
	auto focused_window = Desktop::focusState()->window();
	auto* focused_window_node = this->getNodeFromWindow(focused_window.get());

	// fork: layoutWorkspace() is null for a detached node rather than a crash, and
	// a node that cannot name its own workspace must fall through to the focused
	// window's rather than short-circuit the whole ternary to null.
	auto node_ws = node != nullptr ? node->layoutWorkspace() : nullptr;
	auto origin_ws = valid(node_ws)            ? node_ws
	               : focused_window != nullptr ? focused_window->m_workspace
	                                           : nullptr;

	if (!valid(origin_ws)) return;

	if (workspace == nullptr) {
		hy3_log(LOG, "creating target workspace {} for node move", target.id);

		workspace = State::workspaceState()->create(target.id, origin_ws->monitorID(), target.name);
	}

	const bool moved_floating =
	    focused_window != nullptr
	    && (focused_window_node == nullptr || Fullscreen::controller()->isFullscreen(focused_window));

	if (moved_floating) {
		g_pHyprRenderer->damageWindow(focused_window);
		Desktop::globalWindowController()->moveWindowToWorkspace(focused_window, workspace);
	} else {
		if (node == nullptr) return;

		hy3_log(
		    LOG,
		    "moving node {:x} from workspace {} to workspace {} (follow: {})",
		    (uintptr_t) node,
		    origin->m_id,
		    workspace->m_id,
		    follow
		);

		// fork: refuse a destination running a different layout, and do it
		// before anything is extracted. Falling back to `this` inserted the
		// node into the *origin's* tree while its windows were assigned to
		// another space, leaving the tree and reality permanently disagreeing.
		//
		// Only a space that exists and reports some other tiled algorithm is
		// rejected. A freshly created workspace may not have materialised one
		// yet, and that has to stay a legal move.
		auto* destHy3 = hy3InstanceForWorkspace(workspace);
		if (destHy3 == nullptr && workspace->m_space && workspace->m_space->algorithm()
		    && workspace->m_space->algorithm()->tiledAlgo().get() != nullptr)
		{
			hy3_log(
			    ERR,
			    "refusing to move node {:x} to workspace {}: it is not running hy3",
			    (uintptr_t) node,
			    workspace->m_id
			);
			return;
		}

		auto* destLayout = destHy3 ? destHy3 : this;

		auto* parent_node = node->parent.get();
		auto node_up = parent_node->extractAndMerge(*node, nullptr);

		g_suppressInsert = true;

		for (auto& window: node->windows()) {
			window.layoutTarget()->assignToSpace(workspace->m_space);
		}

		g_suppressInsert = false;

		// fork: insertNode has taken ownership. When it rejects the node it has
		// already destroyed it, so `node` is dangling and everything below -
		// including the follow branch's focus() - would be a use after free.
		if (destLayout->insertNode(std::move(node_up)) == nullptr) {
			hy3_log(
			    ERR,
			    "insertNode rejected node moved to workspace {}; its windows are now there with no node",
			    workspace->m_id
			);
			errorNotif();
			return;
		}

		Desktop::Rule::ruleEngine()->updateAllRules();

		updateTreeTabBars(*node);
		node->updateTabBarRecursive();
		this->recalcGeometry();
	}

	if (follow) {
		auto& monitor = workspace->m_monitor;

		if (workspace->m_isSpecialWorkspace) {
			monitor->setSpecialWorkspace(workspace);
		} else if (origin_ws->m_isSpecialWorkspace) {
			origin_ws->m_monitor->setSpecialWorkspace(nullptr);
		}

		monitor->changeWorkspace(workspace);

		// `node` is the origin workspace's focused node, which is set whenever
		// that workspace holds a tiled window - even when the window actually
		// moved was the floating one. Following it would focus a window that
		// never left, so the floating case has to be handled on its own.
		if (node != nullptr && !moved_floating) {
			node->recalcLayoutGeometry();
			node->focus(warp, Desktop::FOCUS_REASON_KEYBIND);
		} else if (focused_window != nullptr) {
			Desktop::focusState()->fullWindowFocus(focused_window, Desktop::FOCUS_REASON_KEYBIND);

			// not m_reportedPosition: that is published asynchronously by
			// sendWindowSize(), so right after a move it still holds the
			// coordinates the window had on the workspace it just left.
			if (warp) {
				auto box = focused_window->layoutBox();
				Hy3Layout::warpCursorToBox(box.pos(), box.size());
			}

			Desktop::focusState()->rawMonitorFocus(monitor.lock());
		}
	} else {
		// Without follow, nothing has refocused the origin workspace, so focus
		// falls through to whatever is underneath - moving a window off a
		// special workspace drops focus onto the regular workspace below it,
		// even though the scratchpad is still visible and still has windows.
		//
		// Ask hy3 rather than getLastFocusedWindow(): that still names the
		// window just moved away, and focusing it would chase it to its new
		// workspace.
		auto* refocus = this->getWorkspaceFocusedNode(origin);
		if (refocus != nullptr) {
			refocus->focus(false, Desktop::FOCUS_REASON_KEYBIND);
		}
	}
}

void Hy3Layout::changeFocus(const CWorkspace* workspace, FocusShift shift) {
	auto* node = this->getWorkspaceFocusedNode(workspace);
	if (node == nullptr) return;

	switch (shift) {
	case FocusShift::Bottom: goto bottom;
	case FocusShift::Top:
		this->root->focus(false, Desktop::FOCUS_REASON_KEYBIND);
		this->updateGroupBorderColors();
		return;
	case FocusShift::Raise:
		if (node->is_root_group()) goto bottom;
		node->parent->focus(false, Desktop::FOCUS_REASON_KEYBIND);
		this->updateGroupBorderColors();
		return;
	case FocusShift::Lower:
		if (node->is_group() && node->as_group().focused_child != nullptr)
			node->as_group().focused_child->focus(false, Desktop::FOCUS_REASON_KEYBIND);
		this->updateGroupBorderColors();
		return;
	case FocusShift::Tab:
		for (auto& n: node->ancestors()) {
			if (n.parent->as_group().isTab()) {
				n.parent->focus(false, Desktop::FOCUS_REASON_KEYBIND);
				this->updateGroupBorderColors();
				return;
			}
		}
		return;
	case FocusShift::TabNode:
		for (auto& n: node->ancestors()) {
			if (n.parent->as_group().isTab()) {
				n.focus(false, Desktop::FOCUS_REASON_KEYBIND);
				this->updateGroupBorderColors();
				return;
			}
		}
		return;
	}

bottom:
	while (node->is_group() && node->as_group().focused_child != nullptr) {
		node = node->as_group().focused_child;
	}

	node->focus(false, Desktop::FOCUS_REASON_KEYBIND);
	this->updateGroupBorderColors();
	return;
}

Hy3Node* findTabBarAt(Hy3Node& node, Vector2D pos, Hy3Node** focused_node) {
	// clang-format off
	static const auto p_gaps_in = CConfigValue<Config::IComplexConfigValue>("general:gaps_in");
	static const auto tab_bar_height = CConfigValue<Config::INTEGER>("plugin:hy3:tabs:height");
	static const auto tab_bar_padding = CConfigValue<Config::INTEGER>("plugin:hy3:tabs:padding");
	// clang-format on

	// fork: null for a detached node, see Hy3Node::recalcLayoutGeometry
	auto ws = node.layoutWorkspace();
	auto workspace_rule = valid(ws) ? Config::workspaceRuleMgr()->getWorkspaceRuleFor(ws)
	                                : std::optional<Config::CWorkspaceRule>();
	auto gaps_in = workspace_rule.and_then([](auto r) { return r.m_gapsIn; }).value_or(*sc<Config::CCssGapData*>(p_gaps_in.ptr()));

	auto inset = *tab_bar_height + *tab_bar_padding + gaps_in.m_top;

	if (node.is_group()) {
		if (node.hidden) return nullptr;
		// note: tab bar clicks ignore animations
		// all four bounds against visualBox. The top one read logicalBox, which
		// is visualBox grown by the gap offsets, so a click in the gap *above* a
		// group was treated as inside it - and the inset test just below, which
		// decides whether the click hit the tab bar, is relative to visualBox.y.
		if (node.visualBox.x > pos.x || node.visualBox.y > pos.y
		    || node.visualBox.x + node.visualBox.w < pos.x
		    || node.visualBox.y + node.visualBox.h < pos.y)
			return nullptr;

		auto& group = node.as_group();

		if (group.isTab() && group.tab_bar) {
			if (pos.y < node.visualBox.y + inset) {
				auto& children = group.children;
				auto& tab_bar = *group.tab_bar.get();

				auto size = tab_bar.size->value();
				auto x = pos.x - tab_bar.pos->value().x;
				auto child_iter = children.begin();

				for (auto& tab: tab_bar.bar.entries) {
					if (child_iter == children.end()) break;

					if (x > tab.offset->value() * size.x
					    && x < (tab.offset->value() + tab.width->value()) * size.x)
					{
						*focused_node = child_iter->get();
						return &node;
					}

					child_iter = std::next(child_iter);
				}
			}

			if (group.focused_child != nullptr) {
				return findTabBarAt(*group.focused_child, pos, focused_node);
			}
		} else {
			for (auto& child: group.children) {
				if (findTabBarAt(*child, pos, focused_node)) return child.get();
			}
		}
	}

	return nullptr;
}

void Hy3Layout::focusTab(
    const CWorkspace* workspace,
    TabFocus target,
    TabFocusMousePriority mouse,
    bool wrap_scroll,
    int index
) {
	auto* node = this->getWorkspaceRootGroup(workspace);
	if (node == nullptr) return;

	Hy3Node* tab_node = nullptr;
	// initialised: the `goto hastab` below jumps over every assignment to this,
	// and only findTabBarAt()'s contract - that it always writes through the
	// out-param when it returns non-null - kept that from being a read of an
	// uninitialised pointer. Nothing enforces that contract.
	Hy3Node* tab_focused_node = nullptr;

	if (target == TabFocus::MouseLocation || mouse != TabFocusMousePriority::Ignore) {
		// no surf focused at all
		auto ptrSurfaceResource = g_pSeatManager->m_state.pointerFocus.lock();
		if (!ptrSurfaceResource) return;

		auto ptrSurface = CWLSurface::fromResource(ptrSurfaceResource);
		if (!ptrSurface) return;

		// non window-parented surface focused, cant have a tab
		auto view = ptrSurface->view();
		auto* window = dynamic_cast<CWindow*>(view.get());
		if (!window || window->m_isFloating) return;

		auto mouse_pos = g_pInputManager->getMouseCoordsInternal();
		tab_node = findTabBarAt(*node, mouse_pos, &tab_focused_node);
		if (tab_node != nullptr) goto hastab;

		if (target == TabFocus::MouseLocation || mouse == TabFocusMousePriority::Require) return;
	}

	if (tab_node == nullptr) {
		tab_node = this->getWorkspaceFocusedNode(workspace);
		if (tab_node == nullptr) return;

		while (tab_node != nullptr
		       && (tab_node->is_target()
		           || !tab_node->as_group().isTab())
		       && !tab_node->is_root())
			tab_node = tab_node->parent.get();

		if (tab_node == nullptr || tab_node->is_target()
		    || !tab_node->as_group().isTab())
			return;
	}

hastab:
	if (target != TabFocus::MouseLocation) {
		auto& group = tab_node->as_group();
		if (group.focused_child == nullptr || group.children.size() < 2) return;

		auto& children = group.children;
		if (target == TabFocus::Index) {
			int i = 1;

			for (auto& n: children) {
				if (i == index) {
					tab_focused_node = n.get();
					goto cont;
				}

				i++;
			}

			return;
		cont:;
		} else {
			auto node_iter = group.findChild(*group.focused_child);
			if (node_iter == children.end()) return;
			if (target == TabFocus::Left) {
				if (node_iter == children.begin()) {
					if (wrap_scroll) node_iter = std::prev(children.end());
					else return;
				} else node_iter = std::prev(node_iter);

				tab_focused_node = node_iter->get();
			} else {
				if (node_iter == std::prev(children.end())) {
					if (wrap_scroll) node_iter = children.begin();
					else return;
				} else node_iter = std::next(node_iter);

				tab_focused_node = node_iter->get();
			}
		}
	}

	auto* focus = tab_focused_node;
	if (focus == nullptr) return;

	while (focus->is_group() && !focus->as_group().group_focused
	       && focus->as_group().focused_child != nullptr)
		focus = focus->as_group().focused_child;

	focus->focus(false, Desktop::FOCUS_REASON_KEYBIND);
	this->recalcGeometry();
}

void Hy3Layout::setNodeSwallow(const CWorkspace* workspace, SetSwallowOption option) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace);
	if (node == nullptr) return;
	node->assertNotRoot();

	auto* containment = &node->parent->as_group().containment;
	switch (option) {
	case SetSwallowOption::NoSwallow: *containment = false; break;
	case SetSwallowOption::Swallow: *containment = true; break;
	case SetSwallowOption::Toggle: *containment = !*containment; break;
	}
}

void Hy3Layout::killFocusedNode(const CWorkspace* workspace) {
	auto last_window = Desktop::focusState()->window();
	if (last_window != nullptr && last_window->m_isFloating) {
		last_window->sendClose();
	} else {
		auto* node = this->getWorkspaceFocusedNode(workspace);
		if (node == nullptr) return;

		std::vector<PHLWINDOW> windows;
		for (auto& w: node->windows()) windows.push_back(w.m_self.lock());

		for (auto& window: windows) {
			window->setHidden(false);
			window->sendClose();
		}
	}
}

void Hy3Layout::expand(
    const CWorkspace* workspace,
    ExpandOption option,
    ExpandFullscreenOption fs_option
) {
	auto* node = this->getWorkspaceFocusedNodeIfTiled(workspace, false, true);
	if (node == nullptr) return;
	PHLWINDOW window;

	switch (option) {
	case ExpandOption::Expand: {
		node->assertNotRoot();

		if (node->is_group() && !node->as_group().group_focused)
			node->as_group().expand_focused = ExpandFocusType::Stack;

		auto& group = node->parent->as_group();
		group.focused_child = node;
		group.expand_focused = ExpandFocusType::Latch;

		this->recalcGeometry();

		if (node->parent->is_root()) {
			switch (fs_option) {
			case ExpandFullscreenOption::MaximizeAsFullscreen: // goto fullscreen;
			case ExpandFullscreenOption::MaximizeIntermediate:
			case ExpandFullscreenOption::MaximizeOnly: return;
			}
		}
	} break;
	case ExpandOption::Shrink:
		if (node->is_group()) {
			auto& group = node->as_group();

			group.expand_focused = ExpandFocusType::NotExpanded;
			if (group.focused_child->is_group())
				group.focused_child->as_group().expand_focused = ExpandFocusType::Latch;

			this->recalcGeometry();
		}
		break;
	case ExpandOption::Base: {
		if (node->is_group()) {
			node->as_group().collapseExpansions();
			this->recalcGeometry();
		}
		break;
	}
	case ExpandOption::Maximize: break;
	case ExpandOption::Fullscreen: break;
	}

	return;
}

void Hy3Layout::setTabLock(const CWorkspace* workspace, TabLockMode mode) {
	auto* focused = this->getWorkspaceFocusedNode(workspace);
	if (focused == nullptr) return;

	for (auto& node: focused->ancestors()) {
		auto& group = node.parent->as_group();
		if (!group.isTab())
			continue;

		switch (mode) {
		case TabLockMode::Lock: group.locked = true; break;
		case TabLockMode::Unlock: group.locked = false; break;
		case TabLockMode::Toggle: group.locked = !group.locked; break;
		}

		node.parent->updateTabBar();
		return;
	}
}

static void equalizeRecursive(Hy3Node* node, bool recursive) {
	node->size_ratio = 1.0f;

	if (recursive && node->is_group()) {
		for (auto& child: node->as_group().children) {
			equalizeRecursive(child.get(), true);
		}
	}
}

void Hy3Layout::equalize(const CWorkspace* workspace, bool recursive) {
	auto* focused = this->getWorkspaceFocusedNode(workspace);
	if (focused == nullptr) return;

	Hy3Node* target = nullptr;

	if (recursive) {
		target = this->getWorkspaceRootGroup(workspace);
		if (target != nullptr) {
			equalizeRecursive(target, true);
		}
	} else {
		focused->assertNotRoot();
		auto* parent = focused->parent.get();
		equalizeRecursive(parent, false);
		target = parent;
	}

	if (target != nullptr) {
		this->recalcGeometry();
	}
}

void Hy3Layout::warpCursorToBox(const Vector2D& pos, const Vector2D& size) {
	auto cursorpos = Pointer::mgr()->position();

	if (cursorpos.x < pos.x || cursorpos.x >= pos.x + size.x || cursorpos.y < pos.y
	    || cursorpos.y >= pos.y + size.y)
	{
		Hy3Layout::warpCursorWithFocus(pos + size / 2, true);
	}
}

void Hy3Layout::warpCursorWithFocus(const Vector2D& target, bool force) {
	static const auto input_follows_mouse = CConfigValue<Config::INTEGER>("input:follow_mouse");
	static const auto no_warps = CConfigValue<Config::INTEGER>("cursor:no_warps");

	Pointer::pointerController()->warpTo(target, force);

	if (*no_warps && !force) return;

	if (*input_follows_mouse) {
		g_pInputManager->simulateMouseMovement();
	}
}

std::string Hy3Layout::debugNodes() {
	std::string output;

	for (auto* hy3: g_hy3Instances) {
		if (!hy3->root) continue;
		output += hy3->root->debugNode();
		output += "\n";
	}

	return output;
}

bool Hy3Layout::shouldRenderSelected(const CWindow* window) {
	if (window == nullptr) return false;
	if (Desktop::focusState()->window()) return false;

	auto* root = this->getWorkspaceRootGroup(window->m_workspace.get());
	if (root == nullptr || root->as_group().focused_child == nullptr) return false;
	auto* focused = &root->getFocusedNode();

	switch (focused->type()) {
	// fork: try_window() - this is called from the render path, per window per frame
	case Hy3NodeType::Target: return focused->try_window().get() == window;
	case Hy3NodeType::Group: {
		auto* node = this->getNodeFromWindow(window);
		if (node == nullptr) return false;
		return focused->as_group().hasChild(*node);
	}
	}
	return false;
}

Hy3Node* Hy3Layout::getWorkspaceRootGroup(const CWorkspace* workspace) {
	if (!this->root) return nullptr;
	auto& group = this->root->as_group();
	if (group.children.empty()) return nullptr;
	return group.children.front().get();
}

Hy3Node* Hy3Layout::getWorkspaceFocusedNode(
    const CWorkspace* workspace,
    bool ignore_group_focus,
    bool stop_at_expanded
) {
	auto* rootNode = this->getWorkspaceRootGroup(workspace);
	if (rootNode == nullptr) return nullptr;
	return &rootNode->getFocusedNode(ignore_group_focus, stop_at_expanded);
}

// fork: the focused node, for the dispatchers that reshape the tiled tree.
//
// getWorkspaceFocusedNode answers with the tiled node that last held focus
// whether or not the focused window is one - a floating window is not in the
// tree at all. Every dispatcher that restructures the tree therefore
// restructured it behind the floating window the user was looking at: makegroup
// tabbed windows that were never the target, changegroup relaid out a group
// that was not on screen. hy3:movewindow was the visible form of the same
// thing, reported upstream as #223; these are the quiet ones, since nothing
// moves where the user is looking.
//
// Doing nothing is the whole of the answer here. Unlike movewindow, none of
// these has a floating equivalent to fall back to - a floating window cannot be
// tabbed, wrapped or swallowed - and unlike killactive, which upstream does
// guard, there is nothing sensible to do to the floating window instead.
Hy3Node* Hy3Layout::getWorkspaceFocusedNodeIfTiled(
    const CWorkspace* workspace,
    bool ignore_group_focus,
    bool stop_at_expanded
) {
	auto window = Desktop::focusState()->window();
	if (window != nullptr && window->m_isFloating) return nullptr;

	return this->getWorkspaceFocusedNode(workspace, ignore_group_focus, stop_at_expanded);
}

Hy3Node* Hy3Layout::getNodeFromWindow(const CWindow* window) {
	if (!this->root || !window) return nullptr;
	for (auto& w: this->root->windows()) {
		if (&w == window) return getNodeFromTarget(w.layoutTarget());
	}
	return nullptr;
}

static Hy3Node* findNodeFromTargetRecursive(Hy3Node* node, SP<Layout::ITarget> target) {
	if (!node) return nullptr;
	// fork: try_target(), not as_target(). This walks *every* target in the tree
	// looking for one, so as_target() threw on the first expired node it passed,
	// before the search ever reached the node it was asked for. The throw unwinds
	// through Layout::CAlgorithm::removeTarget into CWindow::unmapWindow, which
	// does not catch: SIGABRT on window close, upstream #332.
	if (node->is_target() && node->try_target() == target) {
		return node;
	}
	if (node->is_group()) {
		for (auto& child: node->as_group().children) {
			auto* result = findNodeFromTargetRecursive(child.get(), target);
			if (result) return result;
		}
	}
	return nullptr;
}

Hy3Node* Hy3Layout::getNodeFromTarget(SP<Layout::ITarget> target) {
	// fork: a null target must not be looked up. try_target() above is null for an
	// expired node, so searching for null would return the first dead node found.
	if (!target) return nullptr;
	return findNodeFromTargetRecursive(this->root.get(), target);
}

bool shiftIsForward(ShiftDirection direction) {
	return direction == ShiftDirection::Right || direction == ShiftDirection::Down;
}

bool shiftIsVertical(ShiftDirection direction) {
	return direction == ShiftDirection::Up || direction == ShiftDirection::Down;
}

bool shiftMatchesLayout(Hy3GroupLayout layout, ShiftDirection direction) {
	if (layout == Hy3GroupLayout::Root) return false;
	return (layout == Hy3GroupLayout::SplitV && shiftIsVertical(direction))
	    || (layout != Hy3GroupLayout::SplitV && !shiftIsVertical(direction));
}

Hy3Node* Hy3Layout::shiftOrGetFocus(
    Hy3Node& node,
    ShiftDirection direction,
    bool shift,
    bool once,
    bool visible,
    bool monitor_fallthrough,
    bool warp
) {
	auto* expand_actor = &node.getExpandActor();
	auto* break_origin = &expand_actor->getPlacementActor();
	auto* shift_actor = break_origin;
	auto* break_parent = break_origin->parent.get();

	auto has_broken_once = false;

	// break parents until we hit a container oriented the same way as the shift
	// direction
	while (true) {
		if (break_parent == nullptr) return nullptr;

		auto& group = break_parent->as_group(); // must be a group in order to be a parent

		if (shiftMatchesLayout(group.layout, direction)
		    && (!visible || !group.isTab()))
		{
			// group has the correct orientation

			if (once && shift && has_broken_once) break;
			if (break_origin != shift_actor) has_broken_once = true;

			// if this movement would break out of the group, continue the break loop
			// (do not enter this if) otherwise break.
			//
			// stopping only on `once` let a shift out of a sub-group nested in a
			// tab group escape the tab group entirely: t(h(a, b)) shifting b
			// right gave t(h(a)), b instead of t(h(a), b). a tab parent is a
			// boundary in its own right.
			if ((has_broken_once && shift
			     && (once || (break_parent->parent && break_parent->parent->as_group().isTab())))
			    || !(
			        (!shiftIsForward(direction) && group.children.front().get() == break_origin)
			        || (shiftIsForward(direction) && group.children.back().get() == break_origin)
			    ))
				break;
		}

		if (break_parent->is_root()) {
			// fork: focusMonitor focuses (and warps to) the target itself.
			// Returning it made shiftFocus focus the very same node a second
			// time, with a second recalcGeometry behind it. Hand back nullptr:
			// to every caller that means "nothing further to focus", which is
			// exactly right once focusMonitor has done the work.
			if (!shift) {
				focusMonitor(direction, warp);
				return nullptr;
			}

			// fork: at the edge of the layout, hand the node to the adjacent
			// monitor instead of wrapping it into a new group. shiftMonitor
			// extracts the node, so the traversal state below is dead after this.
			//
			// The warp matters here in a way it does not for a move inside one
			// monitor: with input:follow_mouse the pointer is left behind on the
			// monitor the window came from, and the next keybind acts on
			// whatever it is now hovering instead of the window just moved.
			if (monitor_fallthrough && this->shiftMonitor(node, direction, true, warp))
				return nullptr;

			auto new_layout =
			    shiftIsVertical(direction) ? Hy3GroupLayout::SplitV : Hy3GroupLayout::SplitH;
			break_origin->wrap(new_layout, GroupEphemeralityOption::Standard);
			break_parent = break_origin->parent.get();
			break;
		}

		// special case 1-child nodes so once will only break the group
		if (once && shift && break_origin->is_group() && break_origin->as_group().children.size() == 1) {
			break;
		}

		break_origin = break_parent;
		break_parent = break_origin->parent.get();
	}

	auto& parent_group = break_parent->as_group();
	Hy3Node* target_group = break_parent;
	std::list<UP<Hy3Node>>::iterator insert;

	if (break_origin == parent_group.children.front().get() && !shiftIsForward(direction)) {
		if (!shift) return nullptr;
		insert = parent_group.children.begin();
	} else if (break_origin == parent_group.children.back().get() && shiftIsForward(direction)) {
		if (!shift) return nullptr;
		insert = parent_group.children.end();
	} else {
		auto& group_data = target_group->as_group();

		auto iter = group_data.findChild(*break_origin);
		if (shiftIsForward(direction)) iter = std::next(iter);
		else iter = std::prev(iter);

		auto& node = **iter;
		if (node.is_target()
				|| (node.is_group()
						&& (node.as_group().expand_focused != ExpandFocusType::NotExpanded
								|| node.as_group().locked))
				|| (shift && has_broken_once && (once || parent_group.isTab())))
		{
			if (shift) {
				if (target_group == shift_actor->parent.get()) {
					if (shiftIsForward(direction)) insert = std::next(iter);
					else insert = iter;
				} else {
					if (shiftIsForward(direction)) insert = iter;
					else insert = std::next(iter);
				}
			} else return &(*iter)->getFocusedNode();
		} else {
			// break into neighboring groups until we hit a window
			while (true) {
				target_group = iter->get();
				auto& group_data = target_group->as_group();

				if (group_data.children.empty()) return nullptr; // in theory this would never happen

				bool shift_after = false;

				if (!shift && group_data.isTab()
				    && group_data.focused_child != nullptr)
				{
					iter = group_data.findChild(*group_data.focused_child);
				} else if (visible && group_data.isTab()
				           && group_data.focused_child != nullptr)
				{
					// if the group is tabbed and we're going by visible nodes, jump to the current entry
					iter = group_data.findChild(*group_data.focused_child);
					shift_after = true;
				} else if (shiftMatchesLayout(group_data.layout, direction)
				           || (visible && group_data.isTab()))
				{
					// if the group has the same orientation as movement pick the
					// last/first child based on movement direction
					if (shiftIsForward(direction)) iter = group_data.children.begin();
					else {
						iter = std::prev(group_data.children.end());
						shift_after = true;
					}
				} else {
					if (group_data.focused_child != nullptr) {
						iter = group_data.findChild(*group_data.focused_child);
						shift_after = true;
					} else {
						iter = group_data.children.begin();
					}
				}

				if (shift && once) {
					if (shift_after) insert = std::next(iter);
					else insert = iter;
					break;
				}

				if ((*iter)->is_target()
				    || ((*iter)->is_group()
				        && (*iter)->as_group().expand_focused != ExpandFocusType::NotExpanded))
				{
					if (shift) {
						if (shift_after) insert = std::next(iter);
						else insert = iter;
						break;
					} else {
						return &(*iter)->getFocusedNode();
					}
				}
			}
		}
	}

	auto& group_data = target_group->as_group();

	if (target_group == shift_actor->parent.get()) {
		// Reorder within the same group via splice (handles boundary no-ops naturally)
		auto shift_it = group_data.findChild(*shift_actor);
		group_data.children.splice(insert, group_data.children, shift_it);
		shift_actor->parent->collapseParents(nodeCollapsePolicy());
	} else if (!shift_actor->parent->is_root() && shift_actor->parent->as_group().children.size() == 1 && target_group == shift_actor->parent->parent.get()) {
		// special cased to prevent size being reset to 1 on group break
		auto shift_parent = shift_actor->parent;
		auto shift_actor_u = shift_parent->as_group().extractChildRaw(*shift_actor);
		auto iter = std::ranges::find_if(group_data.children, [&](const auto& other) {
			return other == shift_parent;
		});
		group_data.replaceChild(iter, std::move(shift_actor_u));
	} else {
		auto target_group_p = target_group->self;
		auto* shift_parent = shift_actor->parent.get();
		auto shift_actor_u = shift_parent->as_group().extractChild(*shift_actor);

		group_data.insertChild(insert, std::move(shift_actor_u));

		shift_parent = shift_parent->collapseParents(CollapsePolicy::InvalidOnly);

		if (shift_parent != nullptr) {
			shift_parent->updateTabBarRecursive();
		}

		// Collapse any single-child groups left over from wrapping/extraction
		if (target_group_p) {
			target_group_p->collapseParents(nodeCollapsePolicy());
		}
	}

	node.updateTabBarRecursive();
	node.focus(false, Desktop::FOCUS_REASON_KEYBIND);
	this->recalcGeometry();

	return nullptr;
}

void Hy3Layout::updateAutotileWorkspaces() {
	static const auto autotile_raw_workspaces =
	    CConfigValue<Config::STRING>("plugin:hy3:autotile:workspaces");

	if (*autotile_raw_workspaces == this->autotile.raw_workspaces) {
		return;
	}

	this->autotile.raw_workspaces = *autotile_raw_workspaces;
	this->autotile.workspaces.clear();

	if (this->autotile.raw_workspaces == "all") {
		return;
	}

	this->autotile.workspace_blacklist = this->autotile.raw_workspaces.rfind("not:", 0) == 0;

	const auto autotile_raw_workspaces_filtered = (this->autotile.workspace_blacklist)
	                                                ? this->autotile.raw_workspaces.substr(4)
	                                                : this->autotile.raw_workspaces;

	// split on space and comma
	const std::regex regex {R"([\s,]+)"};
	const auto begin = std::sregex_token_iterator(
	    autotile_raw_workspaces_filtered.begin(),
	    autotile_raw_workspaces_filtered.end(),
	    regex,
	    -1
	);
	const auto end = std::sregex_token_iterator();

	for (auto s = begin; s != end; ++s) {
		try {
			this->autotile.workspaces.insert(std::stoi(*s));
		} catch (...) {
			hy3_log(ERR, "autotile:workspaces: invalid workspace id: {}", (std::string) *s);
		}
	}
}

bool Hy3Layout::shouldAutotileWorkspace(const CWorkspace* workspace) {
	if (this->autotile.workspace_blacklist) {
		return !this->autotile.workspaces.contains(workspace->m_id);
	} else {
		return this->autotile.workspaces.empty()
		    || this->autotile.workspaces.contains(workspace->m_id);
	}
}
