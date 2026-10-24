# Copyright (c) 2026 HandwritingWeb contributors
"""任务数据模型及 FastAPI 表单依赖工厂."""

import inspect
from typing import Literal, TypedDict, get_type_hints

from fastapi import Form
from pydantic import BaseModel, ConfigDict, Field

type TaskStatus = Literal["pending", "processing", "cancelling", "cancelled", "completed", "failed"]


class GenerationTask(TypedDict, total=False):
    """2026-10-15：任务更新与持久化快照的可空字段契约."""

    status: TaskStatus
    stage: str
    message: str
    progress: int
    created_at: float | None
    updated_at: float | None
    response_status_code: int | None
    response_content_type: str | None
    response_headers: dict[str, str]
    response_body: bytes
    result_file_path: str | None
    error_message: str


class GenerateHandwritingParams(BaseModel):
    """手写生成请求参数，文件字段由路由单独绑定."""

    model_config = ConfigDict(populate_by_name=True, serialize_by_alias=True)

    text: str
    font_size: str
    line_spacing: str
    fill: str
    left_margin: str
    top_margin: str
    right_margin: str
    bottom_margin: str
    word_spacing: str
    line_spacing_sigma: str
    font_size_sigma: str
    word_spacing_sigma: str
    perturb_x_sigma: str
    perturb_y_sigma: str
    perturb_theta_sigma: str
    preview: str
    strikethrough_probability: str = "0"
    strikethrough_length_sigma: str = "0"
    strikethrough_width_sigma: str = "0"
    strikethrough_angle_sigma: str = "0"
    strikethrough_width: str = "0"
    ink_depth_sigma: str = "0"
    width: str | None = None
    height: str | None = None
    is_underlined: str = Field("false", alias="isUnderlined")
    background_ruled: str = "false"
    layout_style: Literal["standard", "homework"] = "standard"
    enable_english_spacing: str = Field("false", alias="enableEnglishSpacing")
    font_option: str | None = None
    pdf_save: str = "false"
    full_preview: str = "true"


class _FormDependency[Model: BaseModel]:
    """2026-10-15：显式声明动态签名，调用结果保持传入模型的具体类型."""

    __signature__: inspect.Signature

    def __init__(self, model_cls: type[Model]) -> None:
        self.model_cls = model_cls
        hints: dict[str, object] = get_type_hints(model_cls, include_extras=True)
        parameters: list[inspect.Parameter] = []
        for name, info in model_cls.model_fields.items():
            default: object = ... if info.is_required() else info.default
            parameters.append(
                inspect.Parameter(
                    name,
                    inspect.Parameter.POSITIONAL_OR_KEYWORD,
                    default=Form(default, alias=info.alias or name),
                    annotation=hints.get(name, str),
                ),
            )
        self.__signature__ = inspect.Signature(parameters, return_annotation=model_cls)

    def __call__(self, **kwargs: object) -> Model:
        return self.model_cls.model_validate(kwargs)


def form_dependency_from_model[Model: BaseModel](model_cls: type[Model]) -> _FormDependency[Model]:
    """2026-10-15：从 Pydantic 模型构建保留必填项、默认值与别名的表单依赖."""
    return _FormDependency(model_cls)
