# Runtime accepts value arguments (dtype and integer rank), not generic
# Python type arguments. Rank/dtype validity is established by device tests.
from .. import ndarray as NDArray

__all__ = ["NDArray"]
