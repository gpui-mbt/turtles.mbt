///|
test "path_enabled applies include then exclude" {
  let config = ProjectConfig::{
    include_patterns: ["src/"],
    exclude_patterns: ["gen/"],
    operators: None,
  }
  inspect(config.path_enabled("src/a.mbt"), content="true")
  inspect(config.path_enabled("test/a.mbt"), content="false")
  inspect(config.path_enabled("src/gen/a.mbt"), content="false")
  let no_include = ProjectConfig::{
    include_patterns: [],
    exclude_patterns: ["gen/"],
    operators: None,
  }
  inspect(no_include.path_enabled("test/a.mbt"), content="true")
  inspect(no_include.path_enabled("gen/a.mbt"), content="false")
  let misses_every_include = ProjectConfig::{
    include_patterns: ["absent/"],
    exclude_patterns: [],
    operators: None,
  }
  inspect(misses_every_include.path_enabled("src/a.mbt"), content="false")
}

///|
test "operator_enabled honors an explicit group list" {
  let config = ProjectConfig::{
    include_patterns: [],
    exclude_patterns: [],
    operators: Some([Boolean, Literal]),
  }
  inspect(config.operator_enabled(Boolean), content="true")
  inspect(config.operator_enabled(Literal), content="true")
  inspect(config.operator_enabled(Comparison), content="false")
  inspect(config.operator_enabled(Arithmetic), content="false")
  inspect(config.operator_enabled(Condition), content="false")
}

///|
test "operator_group_from_string rejects unknown groups" {
  let mut raised = false
  try ignore(operator_group_from_string("vibes")) catch {
    _ => raised = true
  } noraise {
    _ => ()
  }
  assert_true(raised)
}

///|
test "operator group names stay stable for reports" {
  inspect(operator_group_name(Comparison), content="comparison")
  inspect(operator_group_name(Boolean), content="boolean")
  inspect(operator_group_name(Arithmetic), content="arithmetic")
  inspect(operator_group_name(Literal), content="literal")
  inspect(operator_group_name(Condition), content="condition")
  inspect(operator_group_name(Boundary), content="boundary")
}

///|
test "an unset operator list enables the five core groups only" {
  let config = default_project_config()
  inspect(config.operator_enabled(Comparison), content="true")
  inspect(config.operator_enabled(Boolean), content="true")
  inspect(config.operator_enabled(Arithmetic), content="true")
  inspect(config.operator_enabled(Literal), content="true")
  inspect(config.operator_enabled(Condition), content="true")
  inspect(config.operator_enabled(Body), content="false")
  inspect(config.operator_enabled(Boundary), content="false")
}

///|
test "boundary is enabled only when named explicitly" {
  let config = ProjectConfig::{
    include_patterns: [],
    exclude_patterns: [],
    operators: Some([Boundary]),
  }
  inspect(config.operator_enabled(Boundary), content="true")
  inspect(config.operator_enabled(Comparison), content="false")
  let both = ProjectConfig::{
    include_patterns: [],
    exclude_patterns: [],
    operators: Some([Comparison, Boundary]),
  }
  inspect(both.operator_enabled(Comparison), content="true")
  inspect(both.operator_enabled(Boundary), content="true")
  inspect(both.operator_enabled(Arithmetic), content="false")
}

///|
test "outcome names stay stable for reports" {
  inspect(outcome_name(Killed), content="KILLED")
  inspect(outcome_name(Survived), content="SURVIVED")
  inspect(outcome_name(Timeout), content="TIMEOUT")
  inspect(outcome_name(Unviable), content="UNVIABLE")
}
