// Synthetic DTOs substitute external event timing only. Deserialize using the
// actual production REST SessionEvent type, never a duplicate permissive schema.
// This is protocol validity, not provider/REST execution or an infrastructure test.
use ah_rest_api_contract::SessionEvent;
use utoipa::PartialSchema;
use serde_json::{Value, json};
use std::{collections::BTreeSet, env, fs};
fn validate_inventory(actual: &BTreeSet<String>, expected: &BTreeSet<String>) -> Result<(), String> {
    if actual == expected { Ok(()) } else { Err(format!("event inventory mismatch: actual={actual:?}, expected={expected:?}")) }
}
fn main() {
    let mut corpus: Value = serde_json::from_slice(&fs::read(env::args().nth(1).expect("corpus path")).unwrap()).unwrap();
    let original = corpus.clone();
    let mut types = BTreeSet::new();
    let mut frames = 0;
    let mut missing_controls = 0;
    let mut enum_controls = 0;
    let mut errors = Vec::new();
    let mut preserved_fields = 0;
    for (scene, events) in original["scenes"].as_object().unwrap() {
        for (index, event) in events.as_array().unwrap().iter().enumerate() {
            let parsed: SessionEvent = match serde_json::from_value(event.clone()) {
                Ok(value) => value,
                Err(error) => { errors.push(format!("{scene}/{}: {error}", event["type"])); continue; }
            };
            let canonical = serde_json::to_value(parsed).unwrap();
            assert_eq!(canonical["type"], event["type"]);
            for (field, value) in event.as_object().unwrap() {
                assert_eq!(canonical.get(field), Some(value), "semantic field lost: {scene}/{field}");
                preserved_fields += 1;
            }
            corpus["scenes"][scene][index] = canonical;
            types.insert(event["type"].as_str().unwrap().to_string());
            frames += 1;
            let mut missing = event.clone();
            missing.as_object_mut().unwrap().remove("timestamp");
            assert!(serde_json::from_value::<SessionEvent>(missing).is_err(), "missing required timestamp accepted");
            missing_controls += 1;
            let field = match event["type"].as_str().unwrap() {
                "participant" | "agent_question" => Some("kind"),
                "status" | "tool_use" | "tool_result" | "workspace" => Some("status"),
                "session_resumed" => Some("deliverer"),
                "session_ended" => Some("outcome"),
                _ => None,
            };
            if let Some(field) = field {
                let mut invalid = event.clone();
                invalid[field] = json!("invalid_protocol_enum_value");
                assert!(serde_json::from_value::<SessionEvent>(invalid).is_err(), "invalid {field} enum accepted");
                enum_controls += 1;
            }
        }
    }
    assert!(errors.is_empty(), "invalid corpus: {errors:?}");
    let schema = serde_json::to_value(SessionEvent::schema()).unwrap();
    if let Ok(path) = env::var("ISONIM_EVENT_SCHEMA_DIAGNOSTIC") { fs::write(path, serde_json::to_string_pretty(&schema).unwrap()).unwrap(); }
    let authoritative_types: BTreeSet<String> = schema["oneOf"].as_array().expect("production tagged enum schema")
        .iter().flat_map(|variant| variant["allOf"].as_array().expect("production tagged variant composition"))
        .filter_map(|component| component["properties"]["type"]["enum"].as_array())
        .flatten()
        .map(|tag| tag.as_str().unwrap().to_owned()).collect();
    assert_eq!(authoritative_types.len(), schema["oneOf"].as_array().unwrap().len(), "every production variant exposes one tag");
    validate_inventory(&types, &authoritative_types).expect("corpus must exactly cover production event discriminators");
    let mut omitted = types.clone();
    omitted.pop_first();
    assert!(validate_inventory(&omitted, &authoritative_types).is_err(), "same inventory guard must reject incomplete coverage");
    if let Some(output) = env::args().nth(2) {
        fs::write(output, serde_json::to_string_pretty(&corpus).unwrap() + "\n").unwrap();
    }
    println!("{}", json!({"status":"passed","productionType":"ah_rest_api_contract::SessionEvent","frames":frames,"types":types,"preservedInputFields":preserved_fields,"canonicalProducerRoundtrip":true,"exactProductionDiscriminators":true,"omissionControlRejected":true,"missingRequiredNegativeControls":missing_controls,"invalidEnumNegativeControls":enum_controls}));
}
