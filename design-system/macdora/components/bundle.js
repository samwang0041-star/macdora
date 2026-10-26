/* @ds-bundle: {"format":4,"namespace":"MacdoraUI","components":[{"name":"Button"},{"name":"Toggle"},{"name":"SegmentedControl"},{"name":"Motion"}]} */
(function (global) {
  "use strict";
  // Portable documentation components. The product uses the linked AppKit controls.
  function Button(props) {
    const p = props || {};
    const button = document.createElement("button");
    button.type = "button";
    button.className = "md-button control-label md-button--" + (p.variant || "secondary");
    button.textContent = p.label || "";
    button.disabled = Boolean(p.disabled);
    if (p.ariaLabel) button.setAttribute("aria-label", p.ariaLabel);
    if (p.onClick) button.addEventListener("click", p.onClick);
    return button;
  }
  function Toggle(props) {
    const p = props || {};
    const label = document.createElement("label");
    label.className = "md-toggle caption";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = Boolean(p.checked);
    input.disabled = Boolean(p.disabled);
    input.setAttribute("aria-label", p.label || "开关");
    const track = document.createElement("span");
    track.className = "md-toggle-track";
    track.setAttribute("aria-hidden", "true");
    const text = document.createElement("span");
    text.textContent = p.label || "";
    input.addEventListener("change", function () { if (p.onChange) p.onChange(input.checked); });
    label.append(input, track, text);
    return label;
  }
  let groupID = 0;
  function SegmentedControl(props) {
    const p = props || {};
    const group = document.createElement("fieldset");
    group.className = "md-segmented";
    const legend = document.createElement("legend");
    legend.className = "md-sr-only";
    legend.textContent = p.label || "选项";
    group.append(legend);
    const name = "md-options-" + (++groupID);
    (p.options || []).forEach(function (option) {
      const label = document.createElement("label");
      const input = document.createElement("input");
      input.type = "radio";
      input.name = name;
      input.value = option.value;
      input.checked = option.value === p.value;
      input.disabled = Boolean(p.disabled);
      const text = document.createElement("span");
      text.className = "control-label";
      text.textContent = option.label;
      input.addEventListener("change", function () { if (input.checked && p.onChange) p.onChange(input.value); });
      label.append(input, text);
      group.append(label);
    });
    return group;
  }
  const Motion = {
    reveal: function (element, reduceMotion) {
      element.getAnimations().forEach(function (animation) { animation.cancel(); });
      if (reduceMotion || global.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
      const style = global.getComputedStyle(element);
      const duration = parseFloat(style.getPropertyValue("--duration-page"));
      const easing = style.getPropertyValue("--ease-standard").trim();
      if (!Number.isFinite(duration) || !easing) return;
      element.animate([
        { opacity: 0, transform: "translateY(3px)" },
        { opacity: 1, transform: "translateY(0)" }
      ], { duration: duration, easing: easing });
    }
  };
  global.MacdoraUI = { Button: Button, Toggle: Toggle, SegmentedControl: SegmentedControl, Motion: Motion };
})(window);
