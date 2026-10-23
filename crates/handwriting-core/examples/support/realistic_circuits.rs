//! 2026-10-23：同一组真实作业电路供拓扑、分页、导出与视觉样张使用。
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Deserialize)]
pub struct Case {
    pub id: String,
    pub title: String,
    pub components: BTreeMap<String, usize>,
    pub source: String,
}

pub fn cases() -> Vec<Case> {
    serde_json::from_str(include_str!("../../tests/fixtures/realistic-circuits.json")).unwrap()
}

pub fn homework(case: &Case) -> String {
    let reasoning = match case.id.as_str() {
        "two-node-dc" => {
            "取底边为参考点。\n按图示电源方向写节点方程：\n(1/R₁+1/R₂+1/R₃)U_(A)−(U_(B))/(R₃) = Uₛ/R₁\n−(U_(A))/(R₃)+(1/R₃+1/R₄)U_(B) = Iₛ\n两节点联立求解，再由 i₃=(U_(A)−U_(B))/R₃ 求中间支路电流。"
        }
        "loaded-rc-ladder" => {
            "电容的导纳为 sC，输出端没有额外外接负载。\n(U₁−Uₛ)/R₁+sC₁U₁+(U₁−Uₒ)/R₂ = 0\n(Uₒ−U₁)/R₂+sC₂Uₒ = 0\n联立得 H(s) = (1)/(1+s(R₁C₁+R₁C₂+R₂C₂)+s²R₁R₂C₁C₂)\n一阶项中的 R₁C₂ 来自级间负载。\n不能直接相乘两个独立 RC 传递函数。"
        }
        "loaded-wheatstone" => {
            "底边接地。电桥非平衡时，中间支路不能当成开路：\n(1/R₁+1/R₂+1/R₅)U_(A)−(U_(B))/(R₅) = Uₛ/R₁\n−(U_(A))/(R₅)+(1/R₃+1/R₄+1/R₅)U_(B) = Uₛ/R₃\ni₅=(U_(A)−U_(B))/R₅\n校验：R₁/R₂=R₃/R₄ 时，U_(A)=U_(B)，故 i₅=0。"
        }
        "bridge-filter-load" => {
            "a、b 接单相交流输入。\n相邻半周由两对二极管交替导通。\n大电容、小纹波近似下：Uₒ≈√2 U_(rms)−2V_(F)\n电容放电间隔约为 (1)/(2f)，于是 ΔU≈(I_(L))/(2fC)\nI_(L)≈(Uₒ)/(R_(L))。\n这里 f 是输入交流频率，输出纹波频率为 2f。"
        }
        _ => "",
    };
    format!("{}\n\n{}\n\n{}", case.title, case.source, reasoning)
}
