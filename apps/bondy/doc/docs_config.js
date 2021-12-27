
function loadScript(url) {
    // create a script DOM node
    var script = document.createElement("script");
    script.src = url;
    script.type= 'text/javascript';
    // add it to the end of the head section of the page
    document.head.appendChild(script);
}


loadScript(
    'https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js'
);

document.addEventListener("DOMContentLoaded", function () {
    mermaid.initialize({ startOnLoad: true});
    let id = 0;
    for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
      const preEl = codeEl.parentElement;
      const graphDefinition = codeEl.textContent;
      const graphEl = document.createElement("div");
      const graphId = "mermaid-graph-" + id++;
      mermaid.render(graphId, graphDefinition, function (svgSource, bindListeners) {
        graphEl.innerHTML = svgSource;
        bindListeners && bindListeners(graphEl);
        preEl.insertAdjacentElement("afterend", graphEl);
        preEl.remove();
      });
    }
  });