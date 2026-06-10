//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_doc_scanner/flutter_doc_scanner_plugin_c_api.h>
#include <flutter_onnxruntime/flutter_onnxruntime_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterDocScannerPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterDocScannerPluginCApi"));
  FlutterOnnxruntimePluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterOnnxruntimePlugin"));
}
