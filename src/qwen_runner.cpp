// ============================================================================
// qwen_runner.cpp - Embedded Native Binary Launcher for Qwen Desktop Widget
// Sets up Lua runtime environment, native shared libraries, and executes main.
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#if defined(_WIN32)
#include <windows.h>
#include <process.h>
#else
#include <unistd.h>
#include <limits.h>
#include <libgen.h>
#include <sys/stat.h>
#endif

static std::string get_exe_dir() {
#if defined(_WIN32)
    char buf[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, buf, MAX_PATH);
    if (len > 0) {
        std::string p(buf, len);
        size_t pos = p.find_last_of("\\/");
        if (pos != std::string::npos) return p.substr(0, pos);
    }
    return ".";
#else
    char buf[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len > 0) {
        buf[len] = '\0';
        char* dir = dirname(buf);
        return std::string(dir);
    }
    return ".";
#endif
}

static bool file_exists(const std::string& p) {
#if defined(_WIN32)
    DWORD attr = GetFileAttributesA(p.c_str());
    return (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY));
#else
    struct stat st;
    return stat(p.c_str(), &st) == 0;
#endif
}

int main(int argc, char** argv) {
    std::string exe_dir = get_exe_dir();
    std::string root_dir = exe_dir + "/..";

#if !defined(_WIN32)
    if (!file_exists(root_dir + "/lib/main.lua") && file_exists("/opt/qwen-widget/lib/main.lua")) {
        root_dir = "/opt/qwen-widget";
    }

    std::string lua_path =
        "/usr/share/lua/5.3/?.lua;/usr/share/lua/5.3/?/init.lua;" +
        root_dir + "/lib/?.lua;" + root_dir + "/?.lua;;";
    std::string lua_cpath =
        root_dir + "/lib/?.so;" +
        "/usr/lib/x86_64-linux-gnu/lua/5.3/?.so;" +
        "/usr/lib/x86_64-linux-gnu/lua/5.3/?/corelgilua51.so;" +
        "/usr/lib/lua/5.3/?.so;;";

    setenv("QWEN_WIDGET_DIR", root_dir.c_str(), 1);
    setenv("QWEN_WIDGET_ROOT", root_dir.c_str(), 1);
    setenv("LUA_PATH", lua_path.c_str(), 1);
    setenv("LUA_CPATH", lua_cpath.c_str(), 1);
    setenv("GDK_BACKEND", "x11", 0);

    const char* old_ld = getenv("LD_LIBRARY_PATH");
    std::string new_ld = root_dir + "/lib/native:" + root_dir + "/lib";
    if (old_ld && old_ld[0]) {
        new_ld += ":" + std::string(old_ld);
    }
    setenv("LD_LIBRARY_PATH", new_ld.c_str(), 1);

    if (chdir(root_dir.c_str()) != 0) {
        // non-fatal
    }

    std::string script = root_dir + "/lib/main.lua";
    std::vector<std::string> candidates = {
        root_dir + "/bin/lua5.3",
        "/opt/qwen-widget/bin/lua5.3",
        "/usr/bin/lua5.3",
        "/usr/local/bin/lua5.3"
    };
    const char* home = getenv("HOME");
    if (home && home[0]) {
        candidates.insert(candidates.begin() + 2, std::string(home) + "/.local/bin/lua5.3");
    }

    for (const auto& cand : candidates) {
        if (file_exists(cand)) {
            std::vector<char*> args;
            args.push_back(const_cast<char*>(cand.c_str()));
            args.push_back(const_cast<char*>(script.c_str()));
            for (int i = 1; i < argc; ++i) {
                args.push_back(argv[i]);
            }
            args.push_back(nullptr);
            execv(cand.c_str(), args.data());
        }
    }

    std::vector<char*> args;
    args.push_back(const_cast<char*>("lua5.3"));
    args.push_back(const_cast<char*>(script.c_str()));
    for (int i = 1; i < argc; ++i) {
        args.push_back(argv[i]);
    }
    args.push_back(nullptr);

    execvp("lua5.3", args.data());
    execvp("luajit", args.data());
    execvp("lua", args.data());

    fprintf(stderr, "[qwen-widget-bin] Error: Lua 5.3 runtime not found.\n");
    return 1;
#else
    std::string script = root_dir + "\\lib\\main.lua";
    std::string lua_exe = root_dir + "\\bin\\lua53.exe";
    std::string cmd = "\"" + lua_exe + "\" \"" + script + "\"";
    return system(cmd.c_str());
#endif
}
