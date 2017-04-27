# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "fluent-plugin-concat-k8s"
  spec.version       = "1.0.0"
  spec.authors       = ["Kenji Okimoto", "Otto Yiu"]
  spec.email         = ["okimoto@clear-code.com"]

  spec.summary       = "Fluentd Filter plugin to concat multiple event messages"
  spec.description   = "Fluentd Filter plugin to concat multiple event messages"
  spec.homepage      = "https://github.com/ottoyiu/fluent-plugin-concat"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject {|f| f.match(%r{^(test|spec|features)/}) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "fluentd", "~> 0.12.21"
  spec.add_development_dependency "bundler", "~> 1.11"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "test-unit", ">= 3.1.0"
  spec.add_development_dependency "test-unit-rr"
  spec.add_development_dependency "appraisal"
end
