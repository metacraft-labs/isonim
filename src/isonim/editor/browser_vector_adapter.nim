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
  const paperLib = globalThis.paper;
  host.dataset.vectorAdapter = 'fabric';
  host.dataset.vectorLibraryBacked = fabricLib ? 'true' : 'false';
  host.dataset.vectorBackendVersion = '7.3.1';
  host.dataset.vectorPathAdapter = paperLib ? 'paper' : 'missing-paper';
  host.dataset.vectorPathLibraryBacked = paperLib ? 'true' : 'false';
  host.dataset.vectorPathBackendVersion = '0.12.18';
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
      if (action === 'import-sample') editor.importSvg(editor.sampleImportSvg);
      if (action === 'zoom-in') editor.zoomBy(1.2);
      if (action === 'zoom-out') editor.zoomBy(0.8);
      if (action === 'pan-right') editor.panBy(48, 24);
      if (action === 'set-fill') editor.setSelectedProperty('fill', '#EF4444');
      if (action === 'set-stroke') editor.setSelectedProperty('stroke', '#22C55E');
      if (action === 'transform-selection') editor.transformSelected();
      if (action === 'boolean-unite') editor.runPaperBoolean('unite');
      if (action === 'boolean-subtract') editor.runPaperBoolean('subtract');
      if (action === 'boolean-intersect') editor.runPaperBoolean('intersect');
      if (action === 'boolean-exclude') editor.runPaperBoolean('exclude');
      if (action === 'move-segment') editor.movePaperSegment();
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
    sampleImportSvg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect id="imported-rect" x="8" y="10" width="30" height="22" fill="#60A5FA" stroke="#1D4ED8" stroke-width="3"/><path id="imported-path" d="M12 48 L28 36 L48 50" fill="none" stroke="#F59E0B" stroke-width="4" stroke-linecap="round"/></svg>',
    canvas,
    svgoOptimize: null,
    sourceChangeSeq: 0,
    paperLib,
    recordSourceChange(operation) {
      const exported = this.exportSvg();
      this.sourceChangeSeq += 1;
      host.dataset.vectorSourceDirty = 'true';
      host.dataset.vectorSourcePending = String(this.sourceChangeSeq);
      host.dataset.vectorSourceOperation = operation;
      host.dataset.vectorSourceLength = String(exported.length);
      host.dispatchEvent(new CustomEvent('isonim-vector-source-change', {
        bubbles: true,
        detail: { operation, length: exported.length }
      }));
      return exported;
    },
    setTool(nextTool) {
      host.dataset.vectorTool = nextTool;
      canvas.isDrawingMode = nextTool === 'pencil';
      canvas.selection = nextTool === 'select';
      canvas.defaultCursor = nextTool === 'select' ? 'default' : 'crosshair';
      if (nextTool === 'rectangle') this.addRect();
      if (nextTool === 'ellipse') this.addEllipse();
      if (nextTool === 'polygon') this.addPolygon();
      if (nextTool === 'star') this.addStar();
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
      host.dataset.vectorZoom = String(canvas.getZoom());
      host.dataset.vectorPanX = String(canvas.viewportTransform ? canvas.viewportTransform[4] : 0);
      host.dataset.vectorPanY = String(canvas.viewportTransform ? canvas.viewportTransform[5] : 0);
      const obj = canvas.getActiveObject();
      host.dataset.vectorControlsVisible = obj && obj.hasControls !== false ? 'true' : 'false';
      host.dataset.vectorActiveFill = obj && obj.fill ? String(obj.fill) : '';
      host.dataset.vectorActiveStroke = obj && obj.stroke ? String(obj.stroke) : '';
      host.dataset.vectorActiveLeft = obj && obj.left != null ? String(Math.round(obj.left)) : '';
      host.dataset.vectorActiveTop = obj && obj.top != null ? String(Math.round(obj.top)) : '';
      host.dataset.vectorActiveAngle = obj && obj.angle != null ? String(Math.round(obj.angle)) : '';
      host.dataset.vectorActiveScaleX = obj && obj.scaleX != null ? String(Number(obj.scaleX).toFixed(2)) : '';
    },
    addRect() {
      const obj = new fabricLib.Rect({
        left: 378, top: 88, width: 112, height: 72, rx: 6, ry: 6,
        fill: 'rgba(59,130,246,0.18)', stroke: '#93C5FD', strokeWidth: 2,
        selectable: true, name: 'drawn-rectangle'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
      this.recordSourceChange('add-rectangle');
    },
    addEllipse() {
      const obj = new fabricLib.Circle({
        left: 398, top: 202, radius: 36, fill: 'rgba(245,158,11,0.20)',
        stroke: '#F59E0B', strokeWidth: 2, selectable: true,
        name: 'drawn-ellipse'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
      this.recordSourceChange('add-ellipse');
    },
    addPolygon() {
      const obj = new fabricLib.Polygon([
        { x: 0, y: -48 }, { x: 42, y: -24 }, { x: 42, y: 24 },
        { x: 0, y: 48 }, { x: -42, y: 24 }, { x: -42, y: -24 }
      ], {
        left: 470, top: 92, fill: 'rgba(147,197,253,0.18)',
        stroke: '#93C5FD', strokeWidth: 2, selectable: true,
        name: 'drawn-polygon'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
      this.recordSourceChange('add-polygon');
    },
    addStar() {
      const points = [];
      for (let i = 0; i < 10; i += 1) {
        const radius = i % 2 === 0 ? 48 : 20;
        const angle = Math.PI * i / 5 - Math.PI / 2;
        points.push({ x: Math.cos(angle) * radius, y: Math.sin(angle) * radius });
      }
      const obj = new fabricLib.Polygon(points, {
        left: 552, top: 240, fill: 'rgba(245,158,11,0.18)',
        stroke: '#F59E0B', strokeWidth: 2, selectable: true,
        name: 'drawn-star'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
      this.recordSourceChange('add-star');
    },
    addLine() {
      const obj = new fabricLib.Line([420, 304, 540, 344], {
        stroke: '#E5E7EB', strokeWidth: 4, selectable: true,
        name: 'drawn-line'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
      this.recordSourceChange('add-line');
    },
    addText() {
      const obj = new fabricLib.Textbox('Text', {
        left: 500, top: 160, width: 120, fontSize: 22, fill: '#F8FAFC',
        selectable: true, name: 'drawn-text'
      });
      canvas.add(obj); canvas.setActiveObject(obj); this.syncSelection();
      this.recordSourceChange('add-text');
    },
    duplicateSelected() {
      const obj = canvas.getActiveObject();
      if (!obj) return false;
      obj.clone().then((clone) => {
        clone.set({ left: obj.left + 16, top: obj.top + 16,
          name: (obj.name || obj.type) + '-copy' });
        canvas.add(clone); canvas.setActiveObject(clone);
        canvas.renderAll(); this.syncSelection();
        this.recordSourceChange('duplicate');
      });
      return true;
    },
    deleteSelected() {
      const obj = canvas.getActiveObject();
      if (!obj) return false;
      canvas.remove(obj); canvas.discardActiveObject();
      canvas.renderAll(); this.syncSelection();
      this.recordSourceChange('delete');
      return true;
    },
    groupSelected() {
      const active = canvas.getActiveObject();
      if (!active || active.type !== 'activeselection') return false;
      const group = active.toGroup();
      group.name = 'fabric-group';
      canvas.setActiveObject(group); canvas.renderAll(); this.syncSelection();
      this.recordSourceChange('group');
      return true;
    },
    ungroupSelected() {
      const active = canvas.getActiveObject();
      if (!active || active.type !== 'group') return false;
      active.toActiveSelection(); canvas.renderAll(); this.syncSelection();
      this.recordSourceChange('ungroup');
      return true;
    },
    importSvg(svgText, options = {}) {
      const wrapped = svgText && svgText.includes('<svg')
        ? svgText
        : `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">${svgText || ''}</svg>`;
      if (typeof fabricLib.loadSVGFromString !== 'function') {
        host.dataset.vectorImportBacked = 'false';
        return false;
      }
      fabricLib.loadSVGFromString(wrapped).then(({ objects }) => {
        const imported = (objects || []).filter(Boolean);
        imported.forEach((obj, index) => {
          obj.set({
            left: (obj.left || 0) + 72 + index * 12,
            top: (obj.top || 0) + 238,
            selectable: true,
            name: obj.name || obj.id || `imported-${obj.type || 'object'}-${index + 1}`
          });
          canvas.add(obj);
        });
        if (imported.length > 0) canvas.setActiveObject(imported[0]);
        canvas.renderAll();
        host.dataset.vectorImportBacked = 'fabric';
        host.dataset.vectorImportedCount = String(imported.length);
        this.syncSelection();
        if (!options.silent) this.recordSourceChange('import');
      }).catch((error) => {
        host.dataset.vectorImportBacked = 'error';
        host.dataset.vectorImportError = String(error && error.message ? error.message : error);
      });
      return true;
    },
    zoomBy(factor) {
      const next = Math.max(0.1, Math.min(8, canvas.getZoom() * factor));
      canvas.zoomToPoint(new fabricLib.Point(canvasEl.width / 2, canvasEl.height / 2), next);
      canvas.requestRenderAll();
      this.syncSelection();
      return true;
    },
    panBy(dx, dy) {
      canvas.relativePan(new fabricLib.Point(dx, dy));
      canvas.requestRenderAll();
      this.syncSelection();
      return true;
    },
    setSelectedProperty(prop, value) {
      const obj = canvas.getActiveObject();
      if (!obj) return false;
      obj.set(prop, value);
      canvas.requestRenderAll();
      this.syncSelection();
      this.recordSourceChange(`property-${prop}`);
      return true;
    },
    addPaperPath(name, pathData, fill = 'rgba(236,72,153,0.22)', stroke = '#EC4899') {
      const obj = new fabricLib.Path(pathData, {
        fill,
        stroke,
        strokeWidth: 3,
        selectable: true,
        name
      });
      canvas.add(obj);
      canvas.setActiveObject(obj);
      canvas.requestRenderAll();
      this.syncSelection();
      return obj;
    },
    makePaperScope() {
      if (!this.paperLib || typeof this.paperLib.PaperScope !== 'function') {
        host.dataset.vectorPathOperationBacked = 'false';
        host.dataset.vectorPathOperationError = 'missing-paper';
        return null;
      }
      const scope = new this.paperLib.PaperScope();
      const offscreen = document.createElement('canvas');
      offscreen.width = 256;
      offscreen.height = 256;
      scope.setup(offscreen);
      return scope;
    },
    runPaperBoolean(operation) {
      const scope = this.makePaperScope();
      if (!scope) return false;
      try {
        const left = new scope.Path.Rectangle({
          point: [84, 84],
          size: [128, 96],
          fillColor: '#60A5FA'
        });
        const right = new scope.Path.Rectangle({
          point: [148, 116],
          size: [128, 96],
          fillColor: '#F97316'
        });
        let result;
        if (operation === 'unite') result = left.unite(right, { insert: false });
        if (operation === 'subtract') result = left.subtract(right, { insert: false });
        if (operation === 'intersect') result = left.intersect(right, { insert: false });
        if (operation === 'exclude') result = left.exclude(right, { insert: false });
        if (!result || !result.pathData) throw new Error(`Paper.js ${operation} produced no pathData`);
        result.fillColor = '#EC4899';
        result.strokeColor = '#F9A8D4';
        const exported = result.exportSVG({ asString: true });
        this.addPaperPath(`paper-${operation}`, result.pathData);
        host.dataset.vectorPathOperationBacked = 'paper';
        host.dataset.vectorPathOperation = operation;
        host.dataset.vectorPathDataLength = String(result.pathData.length);
        host.dataset.vectorPathExportHasPath = String(String(exported).includes('<path'));
        scope.project.clear();
        this.recordSourceChange(`paper-boolean-${operation}`);
        return true;
      } catch (error) {
        host.dataset.vectorPathOperationBacked = 'error';
        host.dataset.vectorPathOperationError = String(error && error.message ? error.message : error);
        return false;
      }
    },
    movePaperSegment() {
      const scope = this.makePaperScope();
      if (!scope) return false;
      try {
        const path = new scope.Path('M 92 304 L 156 244 L 220 304');
        path.strokeColor = '#A78BFA';
        path.strokeWidth = 5;
        path.fillColor = null;
        path.segments[1].point.x = 156;
        path.segments[1].point.y = 216;
        const exported = path.exportSVG({ asString: true });
        this.addPaperPath('paper-moved-segment', path.pathData, '', '#A78BFA');
        host.dataset.vectorPathOperationBacked = 'paper';
        host.dataset.vectorPathOperation = 'move-segment';
        host.dataset.vectorPathDataLength = String(path.pathData.length);
        host.dataset.vectorPathExportHasPath = String(String(exported).includes('<path'));
        scope.project.clear();
        this.recordSourceChange('paper-move-segment');
        return true;
      } catch (error) {
        host.dataset.vectorPathOperationBacked = 'error';
        host.dataset.vectorPathOperationError = String(error && error.message ? error.message : error);
        return false;
      }
    },
    transformSelected() {
      const obj = canvas.getActiveObject();
      if (!obj) return false;
      obj.set({
        angle: (obj.angle || 0) + 15,
        scaleX: (obj.scaleX || 1) * 1.1,
        scaleY: (obj.scaleY || 1) * 1.1
      });
      obj.setCoords();
      canvas.fire('object:modified', { target: obj });
      canvas.requestRenderAll();
      this.syncSelection();
      this.recordSourceChange('transform');
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
  state.importSvg(initialSvg, { silent: true });
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
  if (action === 'import-sample') editor.importSvg(editor.sampleImportSvg);
  if (action === 'zoom-in') editor.zoomBy(1.2);
  if (action === 'zoom-out') editor.zoomBy(0.8);
  if (action === 'pan-right') editor.panBy(48, 24);
  if (action === 'set-fill') editor.setSelectedProperty('fill', '#EF4444');
  if (action === 'set-stroke') editor.setSelectedProperty('stroke', '#22C55E');
  if (action === 'transform-selection') editor.transformSelected();
  if (action === 'boolean-unite') editor.runPaperBoolean('unite');
  if (action === 'boolean-subtract') editor.runPaperBoolean('subtract');
  if (action === 'boolean-intersect') editor.runPaperBoolean('intersect');
  if (action === 'boolean-exclude') editor.runPaperBoolean('exclude');
  if (action === 'move-segment') editor.movePaperSegment();
})()
  """].}

proc currentFabricVectorSvg*[E](host: E): string =
  var exported: cstring
  {.emit: [exported, " = (() => { const editor = ", host,
    " && ", host, ".__isonimVectorEditor; return editor ? editor.exportSvg() : ''; })();"].}
  $exported

proc markFabricVectorSourceSaved*[E](host: E) =
  {.emit: ["""
(() => {
  const host = """, host, """;
  if (!host || !host.__isonimVectorEditor) return;
  host.dataset.vectorSourceDirty = 'false';
  host.dataset.vectorSourceSaved = 'true';
  host.dataset.vectorSourcePending = '0';
})()
  """].}
