use super::{Bounds, PageSample, photo_point};
use crate::drafts::Snapshot;
use serde_json::{Value, json};

type Quad = [[f32; 2]; 4];

pub(crate) struct Drawing {
    pub id: u32,
    pub kind: &'static str,
    pub layout_offset: usize,
    pub paper_corners: Quad,
    pub details: Option<(usize, f32)>,
    pub photo_corners: Quad,
}

impl Drawing {
    pub(super) fn bounds(&self) -> Bounds {
        Bounds::from_corners(self.photo_corners)
    }

    fn reference(&self, draft: &Snapshot<'_>) -> Quad {
        let [a, b, c, d] = self.paper_corners;
        let length = |a: [f32; 2], b: [f32; 2]| (b[0] - a[0]).hypot(b[1] - a[1]);
        let half_w = (length(a, b) + length(d, c)) / 4.;
        let half_h = (length(a, d) + length(b, c)) / 4.;
        let center: [f32; 2] = std::array::from_fn(|i| (a[i] + b[i] + c[i] + d[i]) / 4.);
        [
            [-half_w, -half_h],
            [half_w, -half_h],
            [half_w, half_h],
            [-half_w, half_h],
        ]
        .map(|[x, y]| photo_point(draft, [center[0] + x, center[1] + y]))
    }
}

// 2026-11-27：比较同一位置、同一大小的纸面参考框；当前四角只代表图块外框。
fn edge_differences(current: Quad, reference: Quad) -> [Option<f32>; 4] {
    [(0, 1), (3, 2), (0, 3), (1, 2)].map(|(i, j)| {
        let vector = |q: Quad| [q[j][0] - q[i][0], q[j][1] - q[i][1]];
        let ([x, y], [u, v]) = (vector(current), vector(reference));
        (x.hypot(y) >= 1. && u.hypot(v) >= 1.)
            .then(|| (x * v - y * u).atan2(x * u + y * v).to_degrees().abs())
    })
}

fn bottom_to_top_width_ratio(q: Quad) -> Option<f32> {
    let width = |a: [f32; 2], b: [f32; 2]| (b[0] - a[0]).hypot(b[1] - a[1]);
    let top = width(q[0], q[1]);
    (top >= 1.).then(|| width(q[3], q[2]) / top)
}

pub(super) fn add_check(
    metadata: &mut Value,
    draft: &Snapshot<'_>,
    section: u32,
    page: usize,
    sample: &PageSample,
    size: (u32, u32),
    crop: Option<[u32; 4]>,
) {
    let Some(paper) = &draft.paper else { return };
    if paper.ruled && paper.projection.is_none() {
        return;
    }
    let crop = crop.map(|[x, y, w, h]| {
        Bounds::from_corners(
            [[x, y], [x + w, y], [x + w, y + h], [x, y + h]].map(|p| p.map(|v| v as f32)),
        )
    });
    let mut items = Vec::new();
    let mut total = 0;
    for drawing in &sample.drawings {
        let bounds = drawing.bounds();
        if crop.is_some_and(|b| !bounds.intersects(b)) {
            continue;
        }
        let Some(region) = bounds.region(paper.line_spacing, size) else {
            continue;
        };
        total += 1;
        if items.len() >= 8 {
            continue;
        }
        let reference = paper.projection.as_ref().map(|_| drawing.reference(draft));
        let preview = json!({"draft_id":draft.id,"revision":draft.revision,"section":section,"page":page,
            "view":"review","region":region});
        items.push(json!({"id":drawing.id,"kind":drawing.kind,"current_photo_quad":drawing.photo_corners,
            "paper_aligned_photo_quad":reference,
            "axis_difference_deg_top_bottom_left_right":reference.map(|r|edge_differences(drawing.photo_corners,r)),
            "bottom_to_top_width_ratio":bottom_to_top_width_ratio(drawing.photo_corners),
            "paper_bottom_to_top_width_ratio":reference.and_then(bottom_to_top_width_ratio),
            "separate_detail_alignment":drawing.details.map(|(n,gap)|json!({"visible_parts":n,"max_corner_offset_from_parent_px":gap})),
            "preview_arguments":preview,
            "native_image_arguments":{"draft_id":draft.id,"revision":draft.revision,"section":section,"page":page,
                "view":"image","region":region,"export_blur_px":0},
            "layout_arguments":{"draft_id":draft.id,"revision":draft.revision,"section":section,"page":page,
                "view":"layout","drawings_only":true,"offset":drawing.layout_offset,"limit":1}}));
    }
    if items.is_empty() {
        return;
    }
    let hint = "检查 diagram_perspective_check：把图形作为和正文同一纸面上的整件，看原纸、图和附近字迹。沿原纸横线对照上、下横边或箭杆，再用跨行的纸边、栏线或横线端点核对左右侧边的倾斜及上下宽度变化。";
    let previous = metadata["next_step"].as_str().unwrap_or_default();
    metadata["next_step"] = json!(format!("{previous} {hint}").trim());
    metadata["diagram_perspective_check"] = json!({
        "alignment":paper.summary()["alignment"],"items":items,"visible_drawings_in_crop":total,
        "guidance":hint,
        "interpretation":"四角按左上、右上、右下、左下排列。参考框为以当前大小和位置沿纸面两轴放置后经现有模型投影的框。零角差只说明图框跟随模型；要在原纸上核对模型及图内线条、节点和标签。底边/顶边宽度比反映上下宽窄。rotated 只校准了整体旋转。拆分细节的偏移表示与按外框共同变换的预期位置之差；有意单独移字时可能合理。保留有意的斜线和已协调的图形。参考轴不足时报告不确定。",
        "placement":"图文都偏时，先核对纸面标定，再决定是否用 paper_guides。仅此图不符且能在原纸上定位四角时，使用同版 layout_arguments 找整图 ID，再用 adjust_glyphs(whole_drawing=true, target_quad=实测四角) 同步框线、箭头和标签。只移位置用 whole_drawing=true 与 place_center。对比修前、修后裁区，核对相邻正文；移动后在新位置重查。超过八个图时可用 drawings_only 分页检查。"
    });
}
