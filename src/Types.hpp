#pragma once

// fork: the plain enums the three main headers share, pulled out so they stop
// including each other to reach them.
//
// Hy3Layout.hpp, Hy3Node.hpp and TabGroup.hpp used to form a cycle, held
// together by forward declarations and #includes placed *between* declarations
// rather than at the top - Hy3Layout.hpp opened with `class Hy3Layout;` and one
// enum, then more includes, then more enums. It compiled, but the ordering was
// load bearing and invisible: moving a declaration a few lines broke a
// different header.
//
// Nothing here depends on anything of ours, so this has no include of its own
// beyond what Math::eDirection needs, and every one of the three can include it
// freely.

#include <hyprland/src/helpers/math/Direction.hpp>

enum class GroupEphemeralityOption {
	Ephemeral,
	Standard,
	ForceEphemeral,
};

enum class ShiftDirection {
	Left,
	Up,
	Down,
	Right,
};

inline static constexpr char getShiftDirectionChar(ShiftDirection direction) {
	return direction == ShiftDirection::Left ? 'l'
	     : direction == ShiftDirection::Up   ? 'u'
	     : direction == ShiftDirection::Down ? 'd'
	                                         : 'r';
}

inline static Math::eDirection shiftToMathDirection(ShiftDirection direction) {
	switch (direction) {
	case ShiftDirection::Left: return Math::DIRECTION_LEFT;
	case ShiftDirection::Right: return Math::DIRECTION_RIGHT;
	case ShiftDirection::Up: return Math::DIRECTION_UP;
	case ShiftDirection::Down: return Math::DIRECTION_DOWN;
	}
	return Math::DIRECTION_DEFAULT;
}

enum class Axis { None, Horizontal, Vertical };

enum class FocusShift {
	Top,
	Bottom,
	Raise,
	Lower,
	Tab,
	TabNode,
};

enum class TabFocus {
	MouseLocation,
	Left,
	Right,
	Index,
};

enum class TabFocusMousePriority {
	Ignore,
	Prioritize,
	Require,
};

enum class TabLockMode {
	Lock,
	Unlock,
	Toggle,
};

enum class SetSwallowOption {
	NoSwallow,
	Swallow,
	Toggle,
};

enum class ExpandOption {
	Expand,
	Shrink,
	Base,
	Maximize,
	Fullscreen,
};

enum class ExpandFullscreenOption {
	MaximizeOnly,
	MaximizeIntermediate,
	MaximizeAsFullscreen,
};

// Node-side enums. Here rather than in Hy3Node.hpp because TabGroup.hpp needs
// Hy3GroupLayout without needing the node definitions.
enum class Hy3GroupLayout {
	Root,
	SplitH,
	SplitV,
	Tabbed,
};

enum class Hy3NodeType {
	Target,
	Group,
};

enum class ExpandFocusType {
	NotExpanded,
	Latch,
	Stack,
};

enum class Ephemeral {
	Off,
	Staged,
	Active,
};

enum class CollapsePolicy {
	InvalidOnly,
	EmptySplits,
	SingleNodeGroups,
};
