# Copyright (c) 2026 Simon and Handwriting Web contributors.
import numpy as np
from numpy.typing import NDArray

class DBSCAN:
    labels_: NDArray[np.intp]
    def __init__(self, *, eps: float, min_samples: int) -> None: ...
    def fit(self, data: NDArray[np.float64]) -> DBSCAN: ...
