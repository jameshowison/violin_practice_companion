//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_doc_scanner/flutter_doc_scanner_plugin_c_api.h>
#include <flutter_js/flutter_js_plugin.h>
#include <flutter_onnxruntime/flutter_onnxruntime_plugin.h>
#include <url_launcher_windows/url_launcher_windows.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterDocScannerPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterDocScannerPluginCApi"));
  FlutterJsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterJsPlugin"));
  FlutterOnnxruntimePluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterOnnxruntimePlugin"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
}
