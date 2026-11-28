//! Inspect the prepared section with the same native parser used by the content benchmark.
use handwriting_core::text::{self, Node};
use serde_json::{Value, json};
use std::io::{self, Read};

fn transcript(nodes: &[Node]) -> String {
    nodes
        .iter()
        .map(|node| match node {
            Node::Char(c) => c.to_string(),
            Node::Fraction(a, b) => format!("({})/({})", transcript(a), transcript(b)),
            Node::Scripts { upper, lower } => format!("{}{}", transcript(lower), transcript(upper)),
            Node::Accent(a, _) => transcript(a),
            Node::Radical(a, b) => format!("root({},{})", transcript(a), transcript(b)),
            Node::Newline | Node::Break => "\n".into(),
            _ => String::new(),
        })
        .collect()
}

fn inspect(prepared: &str, english_spacing: bool) -> Value {
    let nodes = text::parse(&text::normalize(prepared, english_spacing));
    let mut components = Vec::<Value>::new();
    let mut text_nodes = Vec::new();
    for (id, node) in nodes.iter().enumerate() {
        let data = match node {
            Node::Table(t) => json!({"id":id,"kind":"table","rows":t.rows.iter().map(|row|
                row.iter().map(|cell| transcript(cell)).collect::<Vec<_>>()).collect::<Vec<_>>()}),
            Node::Fraction(a, b) => {
                json!({"id":id,"kind":"fraction","numerator":transcript(a),"denominator":transcript(b)})
            }
            Node::Circuit(c) => json!({"id":id,"kind":"graph","flowchart":c.flowchart,
                "marks":c.decorations.iter().map(|d|json!({"position":[d.point.0,d.point.1],"kind":d.kind,"text":d.text})).collect::<Vec<_>>(),
                "segments":c.segments.iter().map(|s|json!({"from":[s.start.0,s.start.1],"to":[s.end.0,s.end.1],"arrow":s.end_arrow})).collect::<Vec<_>>()}),
            Node::Char(c) if !c.is_whitespace() => {
                text_nodes.push(json!({"id": id, "text": c}));
                continue;
            }
            _ => continue,
        };
        components.push(data);
    }
    json!({"components":components,"plain_text":transcript(&nodes),"text_nodes":text_nodes,"node_count":nodes.len()})
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut prepared = String::new();
    io::stdin().read_to_string(&mut prepared)?;
    let english_spacing = std::env::args().any(|arg| arg == "--english-spacing");
    println!("{}", inspect(&prepared, english_spacing));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compound_node_ids_share_the_text_node_index_space() {
        let result = inspect("A\n(1)/(2)\nB", false);
        assert_eq!(
            result["components"],
            json!([{"id":2,"kind":"fraction","numerator":"1","denominator":"2"}])
        );
        assert_eq!(
            result["text_nodes"],
            json!([{"id":0,"text":"A"},{"id":4,"text":"B"}])
        );
    }
}
