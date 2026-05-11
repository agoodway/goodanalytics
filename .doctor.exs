%Doctor.Config{
  exception_moduledoc_required: true,
  failed: false,
  ignore_modules: [
    ~r/\.Router/,
    ~r/\.Router\.Helpers/,
    ~r/\.DataCase/,
    ~r/\.TestRepo/,
    ~r/\.TestHelpers/
  ],
  ignore_paths: [
    ~r/test\//
  ],
  min_module_doc_coverage: 80,
  min_module_spec_coverage: 0,
  min_overall_doc_coverage: 80,
  min_overall_spec_coverage: 0,
  min_overall_moduledoc_coverage: 80,
  raise: false,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: false,
  umbrella: false
}
