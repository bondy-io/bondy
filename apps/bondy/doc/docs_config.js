
function loadScript(url) {
    // create a script DOM node
    console.log("Loading script " + url);
    var script = document.createElement("script");
    script.src = url;
    script.type= 'text/javascript';
    // add it to the end of the head section of the page
    document.head.appendChild(script);
}


loadScript(
  'https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js'
);

loadScript(
  'https://cdn.jsdelivr.net/npm/marked/marked.min.js'
);

function renderMD() {
    // Hide the page until it's finished rendering.
    document.body.style.display = "none";
    document.createElement("markdown");

    // Returns array of all markdown tags.
    // var md_tags = document.getElementsByTagName("markdown");
    var md_divs = document.querySelectorAll("div.markdown")

    // Iterate through all the tags, and generate the HTML.
    for (var i = 0; i < md_divs.length; i++) {
        var md_text = md_divs[i].textContent.replace(/^[^\S\n]+/mg, "");
        // md_divs[i].id = "content";
        md_divs[i].innerHTML = marked.parse(md_text);
        // Add remove the old raw markdown.
        md_divs[i].parentNode.replaceChild(md_divs[i]);
    }
    document.body.style.display = ""; // Show the rendered page.
}

function renderMermaid() {

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
}

document.addEventListener("DOMContentLoaded", function () {
    // renderMD();
    mermaid.initialize({ startOnLoad: true});
    renderMermaid();

});