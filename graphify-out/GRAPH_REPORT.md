# Graph Report - /home/ec2-user/kata-benchmark-v2  (2026-04-21)

## Corpus Check
- 2 files · ~91,719 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 14 nodes · 15 edges · 3 communities detected
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]

## God Nodes (most connected - your core abstractions)
1. `add_orange_bar()` - 3 edges
2. `add_slide_title()` - 3 edges
3. `add_textbox()` - 2 edges
4. `add_shape_rect()` - 2 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Communities

### Community 0 - "Community 0"
Cohesion: 0.22
Nodes (0): 

### Community 1 - "Community 1"
Cohesion: 0.5
Nodes (4): add_orange_bar(), add_shape_rect(), add_slide_title(), add_textbox()

### Community 2 - "Community 2"
Cohesion: 1.0
Nodes (0): 

## Knowledge Gaps
- **Thin community `Community 2`** (1 nodes): `md2pdf.py`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `add_orange_bar()` connect `Community 1` to `Community 0`?**
  _High betweenness centrality (0.006) - this node is a cross-community bridge._
- **Why does `add_slide_title()` connect `Community 1` to `Community 0`?**
  _High betweenness centrality (0.006) - this node is a cross-community bridge._