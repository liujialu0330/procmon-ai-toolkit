"""
ProcMon PMC 过滤器生成工具

供 AI 自主调用，按需生成 ProcMon 过滤器配置文件（.pmc），然后传给 capture.ps1 使用。

用法示例：
    # 只采集指定进程
    python gen-filter.py -o filter.pmc --process SdkMinCallDemo.exe

    # 采集指定进程 + 只看文件和注册表操作
    python gen-filter.py -o filter.pmc --process SdkMinCallDemo.exe --operation CreateFile --operation RegOpenKey

    # 按路径过滤（包含匹配）
    python gen-filter.py -o filter.pmc --process SdkMinCallDemo.exe --path-contains Project.ini --path-contains Data\\

    # 排除噪音路径
    python gen-filter.py -o filter.pmc --process SdkMinCallDemo.exe --path-excludes "\\AppData\\" --path-excludes "\\Windows\\"

    # 只看失败事件
    python gen-filter.py -o filter.pmc --process SdkMinCallDemo.exe --result-excludes SUCCESS

    # 组合：进程 + 路径包含 + 排除噪音
    python gen-filter.py -o filter.pmc --process SdkMinCallDemo.exe --path-contains sdk --path-excludes "\\Windows\\"
"""

import argparse
import sys
from pathlib import Path

try:
    from procmon_parser import Rule, dump_configuration
    from procmon_parser.configuration import Column, RuleRelation, RuleAction
except ImportError:
    print("错误：需要 procmon-parser 库，请运行 pip install procmon-parser", file=sys.stderr)
    sys.exit(1)

COLUMN_MAP = {
    "process": Column.PROCESS_NAME,
    "pid": Column.PID,
    "operation": Column.OPERATION,
    "path": Column.PATH,
    "result": Column.RESULT,
    "detail": Column.DETAIL,
    "company": Column.COMPANY,
    "description": Column.DESCRIPTION,
    "command_line": Column.COMMAND_LINE,
    "parent_pid": Column.PARENT_PID,
    "architecture": Column.ARCHITECTURE,
    "image_path": Column.IMAGE_PATH,
    "user": Column.USER,
    "category": Column.CATEGORY,
    "event_class": Column.EVENT_CLASS,
}

RELATION_MAP = {
    "is": RuleRelation.IS,
    "is_not": RuleRelation.IS_NOT,
    "contains": RuleRelation.CONTAINS,
    "excludes": RuleRelation.EXCLUDES,
    "begins_with": RuleRelation.BEGINS_WITH,
    "ends_with": RuleRelation.ENDS_WITH,
    "less_than": RuleRelation.LESS_THAN,
    "more_than": RuleRelation.MORE_THAN,
}


def make_rule(column, relation, value, action):
    return Rule(column, relation, value, action)


def build_rules(args):
    rules = []

    if args.process:
        for proc in args.process:
            rules.append(make_rule(Column.PROCESS_NAME, RuleRelation.IS, proc, RuleAction.INCLUDE))

    if args.operation:
        for op in args.operation:
            rules.append(make_rule(Column.OPERATION, RuleRelation.IS, op, RuleAction.INCLUDE))

    if args.path_contains:
        for path in args.path_contains:
            rules.append(make_rule(Column.PATH, RuleRelation.CONTAINS, path, RuleAction.INCLUDE))

    if args.path_excludes:
        for path in args.path_excludes:
            rules.append(make_rule(Column.PATH, RuleRelation.CONTAINS, path, RuleAction.EXCLUDE))

    if args.result:
        for res in args.result:
            rules.append(make_rule(Column.RESULT, RuleRelation.IS, res, RuleAction.INCLUDE))

    if args.result_excludes:
        for res in args.result_excludes:
            rules.append(make_rule(Column.RESULT, RuleRelation.IS, res, RuleAction.EXCLUDE))

    if args.rule:
        for rule_str in args.rule:
            parts = rule_str.split(",", 3)
            if len(parts) != 4:
                print(f"警告：忽略格式错误的规则 '{rule_str}'，格式应为 'column,relation,value,action'", file=sys.stderr)
                continue
            col_key, rel_key, value, act_key = parts
            column = COLUMN_MAP.get(col_key)
            relation = RELATION_MAP.get(rel_key)
            action = RuleAction.INCLUDE if act_key == "include" else RuleAction.EXCLUDE
            if column is None or relation is None:
                print(f"警告：忽略无法识别的规则 '{rule_str}'", file=sys.stderr)
                continue
            rules.append(make_rule(column, relation, value, action))

    return rules


def main():
    parser = argparse.ArgumentParser(
        description="生成 ProcMon PMC 过滤器配置文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
常用操作类型（--operation）：
  CreateFile, CloseFile, ReadFile, WriteFile, QueryOpen
  QueryDirectory, SetDispositionInformationFile, SetRenameInformationFile
  RegOpenKey, RegQueryValue, RegSetValue, RegCloseKey
  Load Image, Process Create, Process Exit, Thread Create, Thread Exit
  TCP Connect, TCP Send, TCP Receive, UDP Send, UDP Receive

常用结果（--result / --result-excludes）：
  SUCCESS, NAME NOT FOUND, PATH NOT FOUND, ACCESS DENIED,
  BUFFER OVERFLOW, NO MORE ENTRIES, END OF FILE, REPARSE

自定义规则格式（--rule）：
  column,relation,value,action
  例如：process,is,SdkMinCallDemo.exe,include
        """,
    )

    parser.add_argument("-o", "--output", required=True, help="输出 PMC 文件路径")
    parser.add_argument("--process", action="append", help="按进程名过滤（include，可多次指定）")
    parser.add_argument("--operation", action="append", help="按操作类型过滤（include，可多次指定）")
    parser.add_argument("--path-contains", action="append", help="路径包含指定字符串（include）")
    parser.add_argument("--path-excludes", action="append", help="路径包含指定字符串时排除（exclude）")
    parser.add_argument("--result", action="append", help="按结果过滤（include）")
    parser.add_argument("--result-excludes", action="append", help="按结果排除（exclude）")
    parser.add_argument("--rule", action="append", help="自定义规则，格式：column,relation,value,action")
    parser.add_argument("--drop-filtered", action="store_true", default=True, help="丢弃被过滤的事件（默认开启，减小 PML 体积）")
    parser.add_argument("--keep-filtered", action="store_true", help="保留被过滤的事件（仅隐藏，不丢弃）")
    parser.add_argument("--list-columns", action="store_true", help="列出可用的过滤列名")

    args = parser.parse_args()

    if args.list_columns:
        print("可用过滤列名（简写 → ProcMon 列名）：")
        for short, col_enum in sorted(COLUMN_MAP.items()):
            print(f"  {short:20s} → {col_enum.name}")
        return

    rules = build_rules(args)

    if not rules:
        print("错误：至少需要指定一个过滤条件", file=sys.stderr)
        sys.exit(1)

    config = {
        "FilterRules": rules,
        "DestructiveFilter": 0 if args.keep_filtered else 1,
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "wb") as f:
        dump_configuration(config, f)

    print(f"[gen-filter] PMC 过滤器已生成: {output_path}")
    print(f"[gen-filter] 规则数: {len(rules)}")
    print(f"[gen-filter] 丢弃模式: {'开启' if not args.keep_filtered else '关闭'}")
    for i, rule in enumerate(rules):
        action_label = "包含" if rule.action == RuleAction.INCLUDE else "排除"
        col_name = rule.column.name if hasattr(rule.column, 'name') else str(rule.column)
        rel_name = rule.relation.name if hasattr(rule.relation, 'name') else str(rule.relation)
        print(f"  [{i+1}] {action_label}: {col_name} {rel_name} '{rule.value}'")


if __name__ == "__main__":
    main()
