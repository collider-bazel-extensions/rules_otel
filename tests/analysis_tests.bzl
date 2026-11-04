"""Analysis-time tests: install macros, the collector rules' providers,
and the analysis errors for bad attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@rules_otel//:defs.bzl",
    "OtelCollectorInfo",
    "OtelConfigInfo",
    "otel_collector_health_check",
    "otel_collector_server",
    "otel_config",
    "otel_health_check",
    "otel_install",
)

def _has_executable_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, target[DefaultInfo].files_to_run.executable != None,
                 "expected target to expose an executable")
    return analysistest.end(env)

_has_executable_test = analysistest.make(_has_executable_impl)

def _server_info_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[OtelCollectorInfo]
    asserts.equals(env, "0.151.0", info.binary.version)
    asserts.equals(env, "boundary.yaml", info.config.basename)
    return analysistest.end(env)

_server_info_test = analysistest.make(_server_info_impl)

def _config_info_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[OtelConfigInfo]
    asserts.equals(env, ["-service.AllowNoPipelines"], info.feature_gates)
    asserts.equals(env, 1, len(target[OutputGroupInfo]._validation.to_list()))
    return analysistest.end(env)

_config_info_test = analysistest.make(_config_info_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def analysis_test_suite(name):
    s = name + "_subject"
    otel_collector_server(name = s + "_server", config = "//tests/testdata:boundary", tags = ["manual"])
    otel_collector_health_check(name = s + "_health", server = ":" + s + "_server", tags = ["manual"])
    otel_config(
        name = s + "_config",
        src = "//tests/testdata:json.yaml",
        env = {"BACKEND": "http://b:1"},
        feature_gates = ["-service.AllowNoPipelines"],
        tags = ["manual"],
    )
    otel_install(name = s + "_install", tags = ["manual"])
    otel_health_check(name = s + "_install_health", tags = ["manual"])
    otel_collector_server(name = s + "_bad_timeout", ready_timeout = "soon", tags = ["manual"])
    otel_collector_server(name = s + "_bad_env", env = {"NOT-A-NAME": "x"}, tags = ["manual"])

    tests = {
        "_info": (_server_info_test, s + "_server", None),
        "_config_info": (_config_info_test, s + "_config", None),
        "_server_executable": (_has_executable_test, s + "_server", None),
        "_health_executable": (_has_executable_test, s + "_health", None),
        "_install_executable": (_has_executable_test, s + "_install", None),
        "_install_health_executable": (_has_executable_test, s + "_install_health", None),
        "_timeout": (_fails_test, s + "_bad_timeout", "expected a positive number of seconds"),
        "_env": (_fails_test, s + "_bad_env", "expected [A-Za-z_][A-Za-z0-9_]*"),
    }
    for suffix, (rule, target, message) in tests.items():
        if message:
            rule(name = name + suffix, target_under_test = ":" + target, message = message)
        else:
            rule(name = name + suffix, target_under_test = ":" + target)
    native.test_suite(name = name, tests = [":" + name + t for t in tests])
