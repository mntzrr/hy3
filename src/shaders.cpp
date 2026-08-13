#include "shaders.hpp"
#include <string>
#include <stdexcept>

#include <GLES2/gl2.h>
#include <hyprland/src/render/OpenGL.hpp>

#include "log.hpp"
#include "shader_content.hpp"

Hy3Shaders::Hy3Shaders() {
	{
		auto& s = this->tab;
		s.program = makeShared<CShader>();
		// dynamic=true: without it a compile failure ends in RASSERT (which
		// raises SIGABRT even in release builds) rather than returning false,
		// and the fallback in instance() would be dead code.
		if (!s.program->createProgram(std::string(SHADER_TAB_VERT), std::string(SHADER_TAB_FRAG), true)) {
			throw std::runtime_error("hy3 tab shader compilation fails");
		}
		auto program = s.program->program();
		s.proj = glGetUniformLocation(program, "proj");
		s.monitorSize = glGetUniformLocation(program, "monitorSize");
		s.pixelOffset = glGetUniformLocation(program, "pixelOffset");
		s.pixelSize = glGetUniformLocation(program, "pixelSize");
		s.applyBlur = glGetUniformLocation(program, "applyBlur");
		s.blurTex = glGetUniformLocation(program, "blurTex");
		s.opacity = glGetUniformLocation(program, "opacity");
		s.fillColor = glGetUniformLocation(program, "fillColor");
		s.borderColor = glGetUniformLocation(program, "borderColor");
		s.borderWidth = glGetUniformLocation(program, "borderWidth");
		s.outerRadius = glGetUniformLocation(program, "outerRadius");
	}
}

Hy3Shaders* Hy3Shaders::instance() {
	// Null on failure rather than throwing. This is reached from renderTab(),
	// i.e. from inside the compositor's render pass, and a function-local
	// static that throws during initialisation is retried on the next call -
	// so a shader that fails to compile did not throw once, it threw on every
	// frame a tab bar was visible. Callers check and skip drawing instead.
	//
	// Never deleted: releasing the GL program needs a current context, and
	// whether PLUGIN_EXIT has one is unverified. That leaks one program per
	// plugin load, which is a real cost only across repeated reloads.
	static Hy3Shaders* INSTANCE = []() -> Hy3Shaders* {
		try {
			return new Hy3Shaders();
		} catch (const std::exception& e) {
			hy3_log(ERR, "tab shader unavailable, tab bars will not render: {}", e.what());
			return nullptr;
		}
	}();

	return INSTANCE;
}
