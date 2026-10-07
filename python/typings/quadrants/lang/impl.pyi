from typing import Any

class Runtime:
    prog: Any
    def get_num_compiled_functions(self) -> int: ...

class Config:
    arch: Any

def get_runtime() -> Runtime: ...
def current_cfg() -> Config: ...
