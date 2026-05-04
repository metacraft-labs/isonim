## Browser adapter for mature third-party SVG/vector editing backends.
##
## The ViewModels own source-backed editor state. This module owns the
## Fabric.js bridge for browser-only interaction primitives: hit testing,
## selection, transform handles, grouping, drawing helpers, and SVG export.

when not defined(js):
  {.error: "isonim/editor/browser_vector_adapter is JS-only".}

import isonim/editor/types

func toolSlug*(tool: VectorTool): string =
  case tool
  of vtSelect: "select"
  of vtPen: "pen"
  of vtPencil: "pencil"
  of vtRectangle: "rectangle"
  of vtEllipse: "ellipse"
  of vtPolygon: "polygon"
  of vtStar: "star"
  of vtLine: "line"
  of vtText: "text"
  of vtPathEdit: "path-edit"

proc mountFabricVectorEditor*[E](host: E; symbolName, initialSvg,
    activeTool: string) =
  let name = symbolName.cstring
  let svg = initialSvg.cstring
  let tool = activeTool.cstring
  {.emit: ["""
(() => {
  const host = """, host, """;
  const symbolName = """, name, """;
  const initialSvg = """, svg, """;
  const activeTool = """, tool, """;
  const fabricLib = globalThis.fabric;
  host.dataset.vectorAdapter = 'fabric';
  host.dataset.vectorLibraryBacked = fabricLib ? 'true' : 'false';
  host.dataset.vectorBackendVersion = '7.3.1';
  host.dataset.vectorSvgoBacked = 'pending';
  if (!fabricLib) {
    host.dataset.vectorAdapterStatus = 'missing-fabric';
    return;
  }
  if (host.__isonimVectorEditor) {
    host.__isonimVectorEditor.setTool(activeTool);
    return;
  }
  if (!globalThis.__isonimVectorDelegatesInstalled) {
    globalThis.__isonimVectorDelegatesInstalled = true;
    const runDelegatedAction = (event) => {
      const target = event.target && event.target.closest
        ? event.target.closest('[data-vector-action]')
        : null;
      if (!target) return;
      if (event.type === 'keydown' && event.key !== 'Enter' && event.key !== ' ') {
        return;
      }
      const editorHost = document.querySelector('[data-vector-adapter="fabric"][role="application"]');
      const editor = editorHost && editorHost.__isonimVectorEditor;
      if (!editor) return;
      const action = target.getAttribute('data-vector-action');
      if (action === 'duplicate') editor.duplicateSelected();
      if (action === 'delete') editor.deleteSelected();
      if (action === 'group') editor.groupSelected();
      if (action === 'ungroup') editor.ungroupSelected();
      if (action === 'export') editor.exportSvg();
      event.preventDefault();
    };
    document.addEventListener('click', runDelegatedAction);
    document.addEventListener('keydown', runDelegatedAction);
  }

  host.innerHTML = '';
  host.tabIndex = 0;
  host.setAttribute('role', 'application');
  host.setAttribute('aria-label', 'Fabric vector editor canvas');

  const canvasEl = document.createElement('canvas');
  canvasEl.width = 720;
  canvasEl.height = 420;
  canvasEl.setAttribute('data-vector-canvas', 'fabric');
  canvasEl.style.width = '720px';
  canvasEl.style.height = '420px';
  canvasEl.style.display = 'block';
  host.appendChild(canvasEl);

  const canvas = new fabricLib.Canvas(canvasEl, {
    selection: true,
    preserveObjectStacking: true,
    backgroundColor: '#111827'
  });
  canvas.isDrawingMode = false;

  const title = new fabricLib.Textbox(symbolName || 'Vector symbol', {
    left: 36, top: 28, width: 220, fontSize: 18, fill: '#e5e7eb',
    selectable: true, name: 'title'
  });
  const rect = new fabricLib.Rect({
    left: 72, top: 96, width: 180, height: 112, rx: 10, ry: 10,
    fill: 'rgba(59,130,246,0.22)', stroke: '#3B82F6', strokeWidth: 3,
    selectable: true, name: 'card'
  });
  const path = new fabricLib.Path('M 100 160 L 148 205 L 232 108', {
    fill: '', stroke: '#F59E0B', strokeWidth: 8, strokeLineCap: 'round',
    strokeLineJoin: 'round', selectable: true, name: 'check-path'
  });
  const ellipse = new fabricLib.Circle({
    left: 300, top: 124, radius: 44, fill: 'rgba(16,185,129,0.24)',
    stroke: '#10B981', strokeWidth: 3, selectable: true, name: 'badge'
  });
  canvas.add(rect, path, ellipse, title);
  canvas.setActiveObject(rect);
  canvas.renderAll();

  const state = {
    backend: 'fabric',
    version: '7.3.1',
    initialSvg,
    canvas,
    svgoOptimize: null,
    setTool(nextTool) {
      host.dataset.vectorTool = nextTool;
      canvas.isDrawingMode = nextTool === 'pencil';
      canvas.selection = nextTool === 'select';
      canvas.defaultCursor = nextTool === 'select' ? 'default' : 'crosshair';
      if (nextTool === 'rectangle') this.addRect();
      if (nextTool === 'ellipse') this.addEllipse();
      if (nextTool === 'line') this.addLine();
      if (nextTool === 'text') this.addText();
      canvas.renderAll();
    },
    selectedName() {
      const obj = canvas.getActiveObject();
      return obj ? (obj.name || obj.type || 'object') : '';
    },
    syncSelection() {
      host.dataset.selectedVectorObject = this.selectedName();
      host.dataset.vectorObjectCount = String(canvas.getObjects().length);
      host.dataset.vectorSvgLength = String(canvas.toSVG().length);
    },
    addRect() {
      const obj = new fabricLib.Rect({
        left: 378, top: 88, width: 112, height: 72, rx: 6, ry: 6,
        fill: 'rgba(59,130,246,0.18)', stroke: '#93C5FD', strokeWidth: 2,
        selectable: true, name: 'drawn-rectangle'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
    },
    addEllipse() {
      const obj = new fabricLib.Circle({
        left: 398, top: 202, radius: 36, fill: 'rgba(245,158,11,0.20)',
        stroke: '#F59E0B', strokeWidth: 2, selectable: true,
        name: 'drawn-ellipse'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
    },
    addLine() {
      const obj = new fabricLib.Line([420, 304, 540, 344], {
        stroke: '#E5E7EB', strokeWidth: 4, selectable: true,
        name: 'drawn-line'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
    },
    addText() {
      const obj = new fabricLib.Textbox('Text', {
        left: 500, top: 160, width: 120, fontSize: 22, fill: '#F8FAFC',
        selectable: true, name: 'drawn-text'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
    },
    duplicateSelected() {
      const obj = canvas.getActiveObject();
      if (!obj) return false;
      obj.clone().then((clone) => {
        clone.set({ left: obj.left + 16, top: obj.top + 16,
          name: (obj.name || obj.type) + '-copy' });
        canvas.add(clone); canvas.setActiveObject(clone);
        canvas.renderAll(); this.syncSelection();
      });
      return true;
    },
    deleteSelected() {
      const obj = canvas.getActiveObject();
      if (!obj) return false;
      canvas.remove(obj); canvas.discardActiveObject();
      canvas.renderAll(); this.syncSelection();
      return true;
    },
    groupSelected() {
      const active = canvas.getActiveObject();
      if (!active || active.type !== 'activeselection') return false;
      const group = active.toGroup();
      group.name = 'fabric-group';
      canvas.setActiveObject(group); canvas.renderAll(); this.syncSelection();
      return true;
    },
    ungroupSelected() {
      const active = canvas.getActiveObject();
      if (!active || active.type !== 'group') return false;
      active.toActiveSelection(); canvas.renderAll(); this.syncSelection();
      return true;
    },
    exportSvg() {
      const exported = canvas.toSVG();
      const optimized = this.svgoOptimize
        ? this.svgoOptimize(exported, { plugins: ['preset-default'] }).data
        : exported;
      host.dataset.vectorSvgLength = String(optimized.length);
      host.dataset.vectorExportHasSvg = optimized.includes('<svg') ? 'true' : 'false';
      host.dataset.vectorExportOptimized = this.svgoOptimize ? 'true' : 'false';
      return optimized;
    }
  };
  host.__isonimVectorEditor = state;
  globalThis.__isonimVectorEditor = state;

  canvas.on('selection:created', () => state.syncSelection());
  canvas.on('selection:updated', () => state.syncSelection());
  canvas.on('selection:cleared', () => state.syncSelection());
  canvas.on('object:modified', () => state.syncSelection());
  canvas.on('object:added', () => state.syncSelection());
  canvas.on('object:removed', () => state.syncSelection());
  host.addEventListener('keydown', (event) => {
    if (event.key === 'Delete' || event.key === 'Backspace') {
      state.deleteSelected();
      event.preventDefault();
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'd') {
      state.duplicateSelected();
      event.preventDefault();
    } else if (event.key.toLowerCase() === 'g') {
      state.groupSelected();
      event.preventDefault();
    }
  });
  state.setTool(activeTool);
  state.syncSelection();
  import('./svgo.browser.js').then((svgo) => {
    state.svgoOptimize = svgo.optimize;
    host.dataset.vectorSvgoBacked = typeof svgo.optimize === 'function' ? 'true' : 'false';
    host.dataset.vectorSvgoVersion = '4.0.1';
    state.exportSvg();
  }).catch(() => {
    host.dataset.vectorSvgoBacked = 'false';
  });
})()
  """].}

proc syncFabricVectorTool*[E](host: E; activeTool: string) =
  let tool = activeTool.cstring
  {.emit: ["""
(() => {
  const host = """, host, """;
  if (host && host.__isonimVectorEditor) {
    host.__isonimVectorEditor.setTool(""", tool, """);
  }
})()
  """].}

proc runFabricVectorAction*[E](host: E; action: string) =
  let jsAction = action.cstring
  {.emit: ["""
(() => {
  const editor = """, host, """.__isonimVectorEditor;
  if (!editor) return;
  const action = """, jsAction, """;
  if (action === 'duplicate') editor.duplicateSelected();
  if (action === 'delete') editor.deleteSelected();
  if (action === 'group') editor.groupSelected();
  if (action === 'ungroup') editor.ungroupSelected();
  if (action === 'export') editor.exportSvg();
})()
  """].}
