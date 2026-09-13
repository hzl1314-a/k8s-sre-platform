#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
validate-crd-fields.py —— 用 CRD 的真实 schema 校验自定义资源的字段

===============================================================================
为什么需要这个脚本（本项目最贵的一类坑）
===============================================================================
CRD 是结构化 schema。当你 apply 一个自定义资源时：

  * 字段名写错（例如把 `sourceMatchers` 写成 `sourceMatch`）
  * 或者字段在当前 CRD 版本里不存在

Kubernetes **不会报错**，而是把不认识的字段**静默裁剪掉**（prune）。
现象是 apply 返回成功、`kubectl get` 也看得到对象，但那个字段根本没生效——
排查起来极其痛苦，因为没有任何错误信息指向它。

本项目已经栽过两次同类问题（Traefik chart 的 service.type、Loki 的 retention），
所以在上云之前，用「集群上真实安装的 CRD」把清单逐字段对一遍。

===============================================================================
为什么用集群里的 CRD 而不是上游 GitHub 的
===============================================================================
上游 main 分支的 CRD 可能比你集群里装的新（或旧）。校验的意义在于
「我这台集群会不会接受/裁剪这些字段」，所以必须用**集群自己那份**：

  kubectl get crd alertmanagerconfigs.monitoring.coreos.com -o yaml > /tmp/amcfg-crd.yaml

===============================================================================
用法
===============================================================================
  # 1) 从集群导出 CRD
  kubectl get crd alertmanagerconfigs.monitoring.coreos.com -o yaml > /tmp/amcfg-crd.yaml

  # 2) 校验清单
  python3 scripts/validate-crd-fields.py \
      --crd      /tmp/amcfg-crd.yaml \
      --manifest manifests/alerts/alertmanager-config.yaml

  # 清单里有多个资源时，只有 kind 与 CRD 匹配的会被校验，其余自动跳过

退出码：0 = 全部字段合法；1 = 存在未知字段或类型不符（**上云前必须修掉**）
===============================================================================
"""

import argparse
import sys

try:
    import yaml
except ImportError:
    sys.exit("需要 pyyaml：pip install pyyaml")


def load_yaml_docs(path):
    """读取可能含多个文档的 YAML 文件。"""
    with open(path, "r", encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]


def yaml_loader_with_value_tag():
    """
    CRD 里常有 `=` 这样的裸键，YAML 1.1 会把它解析成 tag:yaml.org,2002:value，
    PyYAML 默认构造器不认识。这里补一个构造器兜住。
    """
    class Loader(yaml.SafeLoader):
        pass

    Loader.add_constructor(
        "tag:yaml.org,2002:value",
        lambda loader, node: loader.construct_scalar(node),
    )
    return Loader


def pick_schema_for_version(crd, api_version):
    """从 CRD 中挑出清单所用版本对应的 openAPIV3Schema。"""
    wanted = api_version.split("/")[-1]  # monitoring.coreos.com/v1alpha1 -> v1alpha1
    for v in crd.get("spec", {}).get("versions", []):
        if v.get("name") == wanted:
            return v.get("schema", {}).get("openAPIV3Schema")
    return None


def describe(node):
    """把 schema 节点渲染成人类可读的类型描述。"""
    if not isinstance(node, dict):
        return "?"
    t = node.get("type")
    if t == "array":
        return "array<%s>" % describe(node.get("items", {}))
    if t == "object":
        props = list((node.get("properties") or {}).keys())
        return "object{%s}" % ", ".join(props[:8]) + ("..." if len(props) > 8 else "") + "}"
    return t or "?"


def walk(value, schema, path, problems, is_root=False):
    """
    递归比对 value 与 schema。

    只报「确定的问题」：
      - key 不在 schema.properties 里，且 schema 没有 additionalProperties
      - 基本类型明显不符（str vs int 之类）
    x-kubernetes-preserve-unknown-fields 为 true 时整棵子树放过。
    """
    if not isinstance(schema, dict):
        return
    if schema.get("x-kubernetes-preserve-unknown-fields"):
        return

    stype = schema.get("type")

    # ---- 数组：逐元素递归 ----
    if stype == "array" and isinstance(value, list):
        for i, item in enumerate(value):
            walk(item, schema.get("items", {}), "%s[%d]" % (path, i), problems)
        return

    # ---- 对象 / map ----
    if isinstance(value, dict):
        props = schema.get("properties") or {}
        addl = schema.get("additionalProperties")

        for key, sub in value.items():
            # metadata 由 API Server 管理，且上游生成的示例 CRD 常把它整个省掉，
            # 对它做校验只会产生误报，直接跳过
            if is_root and key == "metadata":
                continue
            if key in props:
                walk(sub, props[key], "%s.%s" % (path, key), problems)
            elif isinstance(addl, dict):
                # 形如 headers: {additionalProperties: {type: string}}
                walk(sub, addl, "%s.%s" % (path, key), problems)
            elif addl is True:
                continue
            else:
                # 未知字段 —— apply 时不报错，但会被静默裁剪
                hint = ""
                if props:
                    import difflib

                    close = difflib.get_close_matches(key, list(props), n=2, cutoff=0.7)
                    if close:
                        hint = "（是否想写 %s？）" % " / ".join(close)
                problems.append("未知字段 %s%s" % (path + "." + key if path else key, hint))
        return

    # ---- 基本类型 ----
    if stype == "string" and not isinstance(value, str):
        problems.append("类型不符 %s: 期望 string，实际 %s" % (path, type(value).__name__))
    elif stype == "integer" and not isinstance(value, int):
        problems.append("类型不符 %s: 期望 integer，实际 %s" % (path, type(value).__name__))
    elif stype == "boolean" and not isinstance(value, bool):
        problems.append("类型不符 %s: 期望 boolean，实际 %s" % (path, type(value).__name__))


def main():
    ap = argparse.ArgumentParser(description="用 CRD schema 校验自定义资源的字段")
    ap.add_argument("--crd", required=True, help="CRD YAML 文件（kubectl get crd <name> -o yaml）")
    ap.add_argument("--manifest", required=True, help="待校验的清单文件（可含多个文档）")
    args = ap.parse_args()

    Loader = yaml_loader_with_value_tag()
    with open(args.crd, "r", encoding="utf-8") as fh:
        crd = yaml.load(fh, Loader=Loader)

    if not isinstance(crd, dict) or crd.get("kind") != "CustomResourceDefinition":
        sys.exit("[错误] --crd 文件不是 CustomResourceDefinition")
    crd_kind = crd.get("spec", {}).get("names", {}).get("kind")
    crd_plural = crd.get("spec", {}).get("names", {}).get("plural")
    print("CRD        : %s (%s)" % (crd_kind, crd_plural))
    print("CRD 版本   : %s" % [v["name"] for v in crd.get("spec", {}).get("versions", [])])
    print("清单       : %s" % args.manifest)
    print("-" * 78)

    docs = load_yaml_docs(args.manifest)
    checked = 0
    total_problems = 0

    for doc in docs:
        kind = doc.get("kind")
        if kind != crd_kind:
            print("跳过 %-28s （kind 与 CRD 不匹配）" % (kind or "<无 kind>"))
            continue

        api_version = doc.get("apiVersion", "")
        schema = pick_schema_for_version(crd, api_version)
        if schema is None:
            print("跳过 %-28s （CRD 中没有版本 %s）" % (kind, api_version))
            total_problems += 1
            continue

        checked += 1
        name = doc.get("metadata", {}).get("name", "<无 name>")
        problems = []
        walk(doc, schema, "", problems, is_root=True)

        if problems:
            total_problems += len(problems)
            print("✗ %s/%s  —— %d 个问题（上云后会被静默裁剪！）" % (kind, name, len(problems)))
            for p in problems:
                print("      %s" % p)
        else:
            print("✓ %s/%s  —— 所有字段都存在于 CRD schema 中" % (kind, name))

    print("-" * 78)
    if checked == 0:
        print("⚠ 没有校验任何对象（清单里没有 kind=%s 的文档）" % crd_kind)
        return 1
    if total_problems:
        print("结果：发现 %d 个问题 —— 修掉再上云" % total_problems)
        return 1
    print("结果：通过（%d 个对象）" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
