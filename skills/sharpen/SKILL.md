---
name: "sharpen"
version: "1.0.0"
display_name: "深化任务（Sharpen）"
description: "把任务做深而不是做大，再重写提示词：想顶尖专家会做什么、从什么原始材料入手、用什么方法工具、靠什么外部证据验证结果。当用户说「这任务怎么做得更深」「重写我的提示词」「专家会怎么做」「sharpen」时使用。任务已经清晰时不必用。"
user-invocable: true
---

I want a deeper version of this task, not a bigger one. Before rewriting it, do four things:

1. Say what a top professional in this field would do here that I'm not asking for.
2. Name the rawest material they would start from instead of what has already been digested for me.
3. Name the specific methods and tools they would use.
4. Say what, other than you or me, would show the result is right.

Then rewrite my prompt to ask for exactly that.

Leave choices that are mine to make open instead of deciding them.
