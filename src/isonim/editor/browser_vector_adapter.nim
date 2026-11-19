## Browser adapter for mature third-party SVG/vector editing backends.
##
## The ViewModels own source-backed editor state. This module owns the
## Fabric.js bridge for browser-only interaction primitives: hit testing,
## selection, transform handles, grouping, drawing helpers, and SVG export.

when not defined(js):
  {.error: "isonim/editor/browser_vector_adapter is JS-only".}

import isonim/editor/types
import isonim/editor/views/view_lifecycle

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
  host.dataset.vectorSymbolName = symbolName;
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
      if (action === 'path-insert') editor.insertPathNode();
      if (action === 'path-delete-node') editor.deleteSelectedPathNode();
      if (action === 'path-convert-smooth') editor.convertSelectedPathNode('smooth');
      if (action === 'path-handle-drag') editor.dragSelectedPathHandle(24, -18);
      if (action === 'path-nudge-right') editor.nudgeSelectedPathNodes(4, 0);
      if (action === 'path-undo') editor.undoPathOperation();
      if (action === 'path-redo') editor.redoPathOperation();
      event.preventDefault();
    };
    document.addEventListener('click', runDelegatedAction);
    document.addEventListener('keydown', runDelegatedAction);
    globalThis.__isonimVectorDelegateCleanup = () => {
      document.removeEventListener('click', runDelegatedAction);
      document.removeEventListener('keydown', runDelegatedAction);
      globalThis.__isonimVectorDelegatesInstalled = false;
    };
  }

  const delegateOwners = globalThis.__isonimVectorDelegateOwners ||= new Set();
  delegateOwners.add(host);
  globalThis.__isonimViewCleanup(host, () => {
    delegateOwners.delete(host);
    if (!delegateOwners.size && globalThis.__isonimVectorDelegateCleanup) {
      globalThis.__isonimVectorDelegateCleanup();
    }
  });
  host.innerHTML = '';
  host.tabIndex = 0;
  host.style.position = 'relative';
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
  const overlay = document.createElement('div');
  overlay.setAttribute('data-vector-path-overlay', 'true');
  overlay.style.position = 'absolute';
  overlay.style.left = '0';
  overlay.style.top = '0';
  overlay.style.width = '720px';
  overlay.style.height = '420px';
  overlay.style.pointerEvents = 'none';
  overlay.style.zIndex = '3';
  host.appendChild(overlay);

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
    paperEditScope: null,
    paperPath: null,
    selectedSegmentIndices: new Set([0]),
    pathHistory: [],
    pathRedo: [],
    editablePathObject: null,
    acceptedSnapshot: null,
    historySnapshots: new Map(),
    shownHistoryId: undefined,
    applyingSnapshot: false,
    fallbackPathData: 'M 100 160 L 148 205 L 232 108',
    nodeId(index) {
      return `node-${index}`;
    },
    indexFromNodeId(id) {
      const match = String(id || '').match(/^node-(\d+)$/);
      return match ? Number(match[1]) : -1;
    },
    makePaperEditScope() {
      if (this.paperEditScope) return this.paperEditScope;
      if (!this.paperLib || typeof this.paperLib.PaperScope !== 'function') {
        host.dataset.vectorPathEditBacked = 'false';
        host.dataset.vectorPathEditError = 'missing-paper';
        return null;
      }
      const scope = new this.paperLib.PaperScope();
      const offscreen = document.createElement('canvas');
      offscreen.width = 720;
      offscreen.height = 420;
      scope.setup(offscreen);
      this.paperEditScope = scope;
      host.dataset.vectorPathEditBacked = 'paper';
      host.dataset.vectorPathSourceBacked = 'paper';
      return scope;
    },
    extractEditablePathData(svgText) {
      const wrapped = svgText && svgText.includes('<svg')
        ? svgText
        : `<svg xmlns="http://www.w3.org/2000/svg">${svgText || ''}</svg>`;
      try {
        const doc = new DOMParser().parseFromString(wrapped, 'image/svg+xml');
        const parserError = doc.querySelector('parsererror');
        if (parserError) throw new Error(parserError.textContent || 'invalid SVG');
        const pathEl = doc.querySelector('path[d]');
        return pathEl ? pathEl.getAttribute('d') || '' : '';
      } catch (error) {
        host.dataset.vectorPathEditError = String(error && error.message ? error.message : error);
        return '';
      }
    },
    setPaperPathData(pathData, operation = 'path-load') {
      const scope = this.makePaperEditScope();
      if (!scope) return false;
      const nextData = pathData || this.fallbackPathData;
      try {
        if (this.paperPath) this.paperPath.remove();
        this.paperPath = new scope.Path(nextData);
        this.paperPath.strokeColor = '#FBBF24';
        this.paperPath.strokeWidth = 5;
        this.paperPath.fillColor = null;
        if (!this.paperPath.segments || this.paperPath.segments.length === 0) {
          throw new Error('Paper.js created no editable path segments');
        }
        const clamped = new Set();
        for (const index of this.selectedSegmentIndices) {
          if (index >= 0 && index < this.paperPath.segments.length) clamped.add(index);
        }
        this.selectedSegmentIndices = clamped.size > 0 ? clamped : new Set([0]);
        host.dataset.vectorPathEditBacked = 'paper';
        host.dataset.vectorPathSourceBacked = 'paper';
        host.dataset.vectorPathOperation = operation;
        return true;
      } catch (error) {
        this.paperPath = null;
        host.dataset.vectorPathEditBacked = 'error';
        host.dataset.vectorPathEditError = String(error && error.message ? error.message : error);
        return false;
      }
    },
    initEditablePath() {
      const initialPathData = this.extractEditablePathData(initialSvg) || this.fallbackPathData;
      if (this.setPaperPathData(initialPathData, 'path-load')) {
        this.renderEditablePath();
        this.syncPathOverlay();
      }
    },
    pathDataFromPaper() {
      return this.paperPath && this.paperPath.pathData ? this.paperPath.pathData : '';
    },
    pathSegments() {
      if (!this.paperPath || !this.paperPath.segments) return [];
      return this.paperPath.segments.map((segment, index) => {
        const inPoint = segment.point.add(segment.handleIn);
        const outPoint = segment.point.add(segment.handleOut);
        const hasIn = Math.abs(segment.handleIn.x) > 0.001 || Math.abs(segment.handleIn.y) > 0.001;
        const hasOut = Math.abs(segment.handleOut.x) > 0.001 || Math.abs(segment.handleOut.y) > 0.001;
        return {
          id: this.nodeId(index),
          index,
          x: segment.point.x,
          y: segment.point.y,
          inX: inPoint.x,
          inY: inPoint.y,
          outX: outPoint.x,
          outY: outPoint.y,
          type: hasIn || hasOut ? 'smooth' : 'corner',
          selected: this.selectedSegmentIndices.has(index)
        };
      });
    },
    selectedPathNodes() {
      return this.pathSegments().filter((node) => node.selected);
    },
    pushPathHistory() {
      this.pathHistory.push(JSON.stringify({
        pathData: this.pathDataFromPaper(),
        selected: Array.from(this.selectedSegmentIndices)
      }));
      if (this.pathHistory.length > 20) this.pathHistory.shift();
      this.pathRedo = [];
      host.dataset.vectorPathUndoDepth = String(this.pathHistory.length);
      host.dataset.vectorPathRedoDepth = String(this.pathRedo.length);
    },
    restorePathSnapshot(snapshot, operation) {
      if (!snapshot) return false;
      const parsed = JSON.parse(snapshot);
      this.selectedSegmentIndices = new Set(parsed.selected || [0]);
      if (!this.setPaperPathData(parsed.pathData, operation)) return false;
      this.renderEditablePath();
      this.syncPathOverlay();
      host.dataset.vectorPathKeyboardOperation = operation;
      this.recordSourceChange(operation);
      return true;
    },
    undoPathOperation() {
      if (!this.pathHistory.length) return false;
      this.pathRedo.push(JSON.stringify({
        pathData: this.pathDataFromPaper(),
        selected: Array.from(this.selectedSegmentIndices)
      }));
      const snapshot = this.pathHistory.pop();
      host.dataset.vectorPathUndoDepth = String(this.pathHistory.length);
      host.dataset.vectorPathRedoDepth = String(this.pathRedo.length);
      return this.restorePathSnapshot(snapshot, 'path-undo');
    },
    redoPathOperation() {
      if (!this.pathRedo.length) return false;
      this.pathHistory.push(JSON.stringify({
        pathData: this.pathDataFromPaper(),
        selected: Array.from(this.selectedSegmentIndices)
      }));
      const snapshot = this.pathRedo.pop();
      host.dataset.vectorPathUndoDepth = String(this.pathHistory.length);
      host.dataset.vectorPathRedoDepth = String(this.pathRedo.length);
      return this.restorePathSnapshot(snapshot, 'path-redo');
    },
    renderEditablePath() {
      if (!this.paperPath) return false;
      if (this.editablePathObject) {
        canvas.remove(this.editablePathObject);
      }
      this.editablePathObject = new fabricLib.Path(this.pathDataFromPaper(), {
        fill: '',
        stroke: '#FBBF24',
        strokeWidth: 5,
        strokeLineCap: 'round',
        strokeLineJoin: 'round',
        selectable: true,
        name: 'editable-path'
      });
      canvas.add(this.editablePathObject);
      canvas.setActiveObject(this.editablePathObject);
      canvas.requestRenderAll();
      this.syncSelection();
      return true;
    },
    screenPoint(node) {
      const vt = canvas.viewportTransform || [1, 0, 0, 1, 0, 0];
      return {
        x: node.x * vt[0] + vt[4],
        y: node.y * vt[3] + vt[5]
      };
    },
    syncPathOverlay() {
      overlay.innerHTML = '';
      const nodes = this.pathSegments();
      const zoom = canvas.getZoom();
      const minHitTarget = Math.max(14, Math.round(14 / Math.max(0.5, zoom)));
      nodes.forEach((node, index) => {
        const point = this.screenPoint(node);
        const anchor = document.createElement('button');
        anchor.type = 'button';
        anchor.setAttribute('data-vector-anchor', node.id);
        anchor.setAttribute('aria-label', `Path anchor ${index + 1}`);
        anchor.style.position = 'absolute';
        anchor.style.left = `${point.x - minHitTarget / 2}px`;
        anchor.style.top = `${point.y - minHitTarget / 2}px`;
        anchor.style.width = `${minHitTarget}px`;
        anchor.style.height = `${minHitTarget}px`;
        anchor.style.borderRadius = '999px';
        anchor.style.border = node.selected ? '2px solid #F97316' : '2px solid #FBBF24';
        anchor.style.background = node.selected ? '#FED7AA' : '#111827';
        anchor.style.boxShadow = '0 0 0 2px rgba(15,23,42,0.85)';
        anchor.style.pointerEvents = 'auto';
        anchor.style.padding = '0';
        anchor.addEventListener('click', (event) => {
          this.selectPathNode(node.id, event.shiftKey);
          event.preventDefault();
        });
        anchor.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            this.selectPathNode(node.id, event.shiftKey);
            event.preventDefault();
          }
        });
        anchor.addEventListener('pointerdown', (event) => {
          anchor.setPointerCapture(event.pointerId);
          const pointerId = event.pointerId;
          const startX = event.clientX;
          const startY = event.clientY;
          const startNodeX = node.x;
          const startNodeY = node.y;
          // What the drag puts back when it is cancelled: the path, its
          // selected nodes and its history before the drag.
          const before = {
            pathData: this.pathDataFromPaper(),
            selected: Array.from(this.selectedSegmentIndices),
            history: this.pathHistory.slice(),
            redo: this.pathRedo.slice()
          };
          let moved = false;
          let ended = false;
          // The anchor holding the pointer capture: moving the node redraws
          // the overlay, so the capture moves to the node's new anchor.
          let captor = anchor;
          const move = (moveEvent) => {
            if (moveEvent.pointerId !== pointerId) return;
            const dx = (moveEvent.clientX - startX) / canvas.getZoom();
            const dy = (moveEvent.clientY - startY) / canvas.getZoom();
            if (dx === 0 && dy === 0) return;
            // The drag's first movement is its one path-history entry, as
            // a nudge's is.
            if (!moved) this.pushPathHistory();
            moved = true;
            this.movePathNodeTo(node.id, startNodeX + dx, startNodeY + dy, false);
            const next = overlay.querySelector(`[data-vector-anchor="${node.id}"]`);
            if (next && next !== captor) {
              captor = next;
              try { next.setPointerCapture(pointerId); } catch (_) {}
              next.addEventListener('lostpointercapture', lost);
            }
          };
          const finish = () => {
            ended = true;
            document.removeEventListener('pointermove', move);
            document.removeEventListener('pointerup', up);
            document.removeEventListener('pointercancel', cancelled, true);
            document.removeEventListener('keydown', escape, true);
          };
          const up = (upEvent) => {
            if (upEvent.pointerId !== pointerId) return;
            finish();
            // A click on a node selects it; only a drag that moved it is
            // an edit.
            if (!moved) return;
            this.recordSourceChange('path-pointer-drag');
            host.dataset.vectorPathPointerDrag = 'true';
          };
          // Escape, pointer cancellation or a lost capture end the drag
          // without an edit: the path, its selection and its history go
          // back to before the drag, and nothing is recorded.
          const cancel = (why) => {
            if (ended) return;
            finish();
            if (captor.isConnected && captor.hasPointerCapture(pointerId)) {
              captor.releasePointerCapture(pointerId);
            }
            host.dataset.vectorGestureCancelled = `node-${why}`;
            if (!moved) return;
            this.selectedSegmentIndices = new Set(before.selected.length ? before.selected : [0]);
            this.setPaperPathData(before.pathData, 'path-drag-cancel');
            this.pathHistory = before.history;
            this.pathRedo = before.redo;
            host.dataset.vectorPathUndoDepth = String(this.pathHistory.length);
            host.dataset.vectorPathRedoDepth = String(this.pathRedo.length);
            this.renderEditablePath();
            this.syncPathOverlay();
          };
          const cancelled = (cancelEvent) => {
            if (cancelEvent.pointerId === pointerId) cancel('pointercancel');
          };
          const escape = (keyEvent) => {
            if (keyEvent.key !== 'Escape') return;
            keyEvent.preventDefault();
            keyEvent.stopPropagation();
            cancel('escape');
          };
          // A capture lost by the anchor holding it. (The overlay's own
          // redraw removes that anchor; a removed element's lost capture is
          // fired at the document, not here, and the capture has already
          // moved to the node's new anchor.)
          function lost(lostEvent) {
            if (lostEvent.pointerId === pointerId) cancel('lost-capture');
          }
          anchor.addEventListener('lostpointercapture', lost);
          document.addEventListener('pointermove', move);
          document.addEventListener('pointerup', up);
          document.addEventListener('pointercancel', cancelled, true);
          document.addEventListener('keydown', escape, true);
          globalThis.__isonimViewCleanup(host, () => {
            finish();
            if (captor.isConnected && captor.hasPointerCapture(pointerId)) captor.releasePointerCapture(pointerId);
          });
        });
        overlay.appendChild(anchor);
        if (node.type !== 'corner') {
          for (const [kind, hx, hy] of [['in', node.inX, node.inY], ['out', node.outX, node.outY]]) {
            const handle = document.createElement('span');
            handle.setAttribute('data-vector-handle', `${node.id}-${kind}`);
            handle.style.position = 'absolute';
            handle.style.left = `${hx * (canvas.viewportTransform ? canvas.viewportTransform[0] : 1) + (canvas.viewportTransform ? canvas.viewportTransform[4] : 0) - 4}px`;
            handle.style.top = `${hy * (canvas.viewportTransform ? canvas.viewportTransform[3] : 1) + (canvas.viewportTransform ? canvas.viewportTransform[5] : 0) - 4}px`;
            handle.style.width = '8px';
            handle.style.height = '8px';
            handle.style.border = '1px solid #93C5FD';
            handle.style.background = '#DBEAFE';
            handle.style.pointerEvents = 'none';
            overlay.appendChild(handle);
          }
        }
      });
      host.dataset.vectorPathOverlayVisible = nodes.length > 0 ? 'true' : 'false';
      host.dataset.vectorPathAnchorCount = String(nodes.length);
      host.dataset.vectorPathPaperSegmentCount = String(this.paperPath && this.paperPath.segments ? this.paperPath.segments.length : 0);
      host.dataset.vectorPathHandleCount = String(overlay.querySelectorAll('[data-vector-handle]').length);
      host.dataset.vectorPathHitTargetMin = String(minHitTarget);
      host.dataset.vectorPathDataLength = String(this.pathDataFromPaper().length);
    },
    selectPathNode(id, append = false) {
      const index = this.indexFromNodeId(id);
      if (!this.paperPath || index < 0 || index >= this.paperPath.segments.length) return false;
      if (!append) this.selectedSegmentIndices.clear();
      this.selectedSegmentIndices.add(index);
      host.dataset.vectorPathSelectedNodes = this.selectedPathNodes().map((item) => item.id).join(',');
      this.syncPathOverlay();
      return true;
    },
    movePathNodeTo(id, x, y, pushHistory = true) {
      const index = this.indexFromNodeId(id);
      if (!this.paperPath || index < 0 || index >= this.paperPath.segments.length) return false;
      if (pushHistory) this.pushPathHistory();
      const segment = this.paperPath.segments[index];
      segment.point.x = x;
      segment.point.y = y;
      this.selectedSegmentIndices.add(index);
      this.renderEditablePath();
      this.syncPathOverlay();
      host.dataset.vectorPathOperation = 'move-node';
      host.dataset.vectorPathKeyboardOperation = 'move-node';
      return true;
    },
    nudgeSelectedPathNodes(dx, dy) {
      if (!this.paperPath || this.selectedSegmentIndices.size === 0) return false;
      this.pushPathHistory();
      this.selectedSegmentIndices.forEach((index) => {
        const segment = this.paperPath.segments[index];
        if (!segment) return;
        segment.point.x += dx;
        segment.point.y += dy;
      });
      this.renderEditablePath();
      this.syncPathOverlay();
      host.dataset.vectorPathOperation = 'nudge-node';
      host.dataset.vectorPathKeyboardOperation = 'nudge-node';
      this.recordSourceChange('path-nudge');
      return true;
    },
    insertPathNode() {
      if (!this.paperPath) return false;
      const selected = this.selectedPathNodes()[0] || this.pathSegments()[0];
      const index = selected ? selected.index : 0;
      this.pushPathHistory();
      const base = selected || { x: 100, y: 160 };
      const next = new this.paperEditScope.Point(base.x + 32, base.y - 18);
      this.paperPath.insert(index + 1, next);
      this.selectedSegmentIndices = new Set([index + 1]);
      this.renderEditablePath();
      this.syncPathOverlay();
      host.dataset.vectorPathOperation = 'insert-node';
      this.recordSourceChange('path-insert-node');
      return true;
    },
    deleteSelectedPathNode() {
      if (!this.paperPath || this.paperPath.segments.length <= 2) return false;
      if (this.selectedSegmentIndices.size === 0) return false;
      this.pushPathHistory();
      Array.from(this.selectedSegmentIndices).sort((a, b) => b - a).forEach((index) => {
        if (this.paperPath.segments[index]) this.paperPath.removeSegment(index);
      });
      this.selectedSegmentIndices = new Set([0]);
      this.renderEditablePath();
      this.syncPathOverlay();
      host.dataset.vectorPathOperation = 'delete-node';
      this.recordSourceChange('path-delete-node');
      return true;
    },
    convertSelectedPathNode(type) {
      if (!this.paperPath || this.selectedSegmentIndices.size === 0) return false;
      this.pushPathHistory();
      this.selectedSegmentIndices.forEach((index) => {
        const segment = this.paperPath.segments[index];
        if (!segment) return;
        if (type === 'smooth') {
          segment.handleIn = new this.paperEditScope.Point(-18, 0);
          segment.handleOut = new this.paperEditScope.Point(18, 0);
        } else {
          segment.handleIn = new this.paperEditScope.Point(0, 0);
          segment.handleOut = new this.paperEditScope.Point(0, 0);
        }
      });
      this.renderEditablePath();
      this.syncPathOverlay();
      host.dataset.vectorPathOperation = `convert-${type}`;
      this.recordSourceChange(`path-convert-${type}`);
      return true;
    },
    dragSelectedPathHandle(dx, dy) {
      const selected = this.selectedPathNodes()[0];
      if (!selected || !this.paperPath) return false;
      this.pushPathHistory();
      const segment = this.paperPath.segments[selected.index];
      if (!segment) return false;
      segment.handleOut.x += dx;
      segment.handleOut.y += dy;
      this.renderEditablePath();
      this.syncPathOverlay();
      host.dataset.vectorPathOperation = 'drag-handle';
      this.recordSourceChange('path-handle-drag');
      return true;
    },
    // The canvas as the editor accepted it: each object with the properties
    // a drawing, a move, a resize, a rotation, a skew, a style or a path edit
    // changes.
    acceptedProps(obj) {
      const keys = ['left', 'top', 'width', 'height', 'scaleX', 'scaleY',
        'angle', 'skewX', 'skewY', 'flipX', 'flipY', 'fill', 'stroke',
        'strokeWidth', 'opacity', 'visible', 'rx', 'ry', 'radius', 'text'];
      const props = {};
      keys.forEach((key) => { if (obj[key] !== undefined) props[key] = obj[key]; });
      if (Array.isArray(obj.path)) props.path = JSON.parse(JSON.stringify(obj.path));
      if (Array.isArray(obj.points)) props.points = JSON.parse(JSON.stringify(obj.points));
      return props;
    },
    // A multi-selection's members hold coordinates relative to the
    // selection; a snapshot of them is taken with the selection released (its
    // transform applied to each member), then the same members are selected
    // again. (fabric's SVG export already writes them at canvas positions.)
    releasingSelection(fn) {
      const active = canvas.getActiveObject();
      if (!active || !(active instanceof fabricLib.ActiveSelection)) return fn();
      const members = active.getObjects();
      canvas.discardActiveObject();
      try {
        return fn();
      } finally {
        const kept = members.filter((obj) => canvas.getObjects().includes(obj));
        if (kept.length > 1) {
          canvas.setActiveObject(new fabricLib.ActiveSelection(kept, { canvas }));
        } else if (kept.length === 1) {
          canvas.setActiveObject(kept[0]);
        }
      }
    },
    snapshotCanvas() {
      return this.releasingSelection(() => ({
        objects: canvas.getObjects().map((obj) => ({ obj, props: this.acceptedProps(obj) })),
        // The Paper.js editable path behind the canvas's editable-path
        // shape: its nodes, the selected nodes, its undo/redo stacks and
        // which canvas object draws it. A path-node edit changes these as
        // well as the canvas.
        path: {
          pathData: this.pathDataFromPaper(),
          selected: Array.from(this.selectedSegmentIndices || []),
          editable: this.editablePathObject,
          history: (this.pathHistory || []).slice(),
          redo: (this.pathRedo || []).slice()
        }
      }));
    },
    // `historyId` names the editor's vector history entry for the commit
    // that accepted this canvas; an undo or redo that puts that entry on top
    // of the history shows this canvas again (`showHistory`). Without one
    // (the loaded symbol), the canvas is the one for the entry shown.
    acceptCurrent(historyId) {
      const snapshot = this.snapshotCanvas();
      this.acceptedSnapshot = snapshot;
      if (historyId !== undefined && historyId !== null && historyId >= 0) {
        this.historySnapshots.set(historyId, snapshot);
        this.shownHistoryId = historyId;
      } else if (this.shownHistoryId !== undefined) {
        this.historySnapshots.set(this.shownHistoryId, snapshot);
      }
      host.dataset.vectorAcceptedCount = String(snapshot.objects.length);
    },
    applySnapshot(snapshot) {
      if (!snapshot) return false;
      this.applyingSnapshot = true;
      try {
        const keep = new Set(snapshot.objects.map((entry) => entry.obj));
        canvas.discardActiveObject();
        canvas.getObjects().slice().forEach((obj) => { if (!keep.has(obj)) canvas.remove(obj); });
        snapshot.objects.forEach((entry, index) => {
          if (!canvas.getObjects().includes(entry.obj)) canvas.add(entry.obj);
          entry.obj.set(entry.props);
          if (typeof entry.obj.setCoords === 'function') entry.obj.setCoords();
          if (typeof canvas.moveObjectTo === 'function') canvas.moveObjectTo(entry.obj, index);
        });
        // The editable path as accepted: its nodes and selection, its
        // history, and the canvas object that draws it again (the one just
        // restored; a refused node edit had replaced it). Not through
        // renderEditablePath or restorePathSnapshot, which would draw a new
        // object and record a source change.
        const path = snapshot.path;
        if (path && path.pathData) {
          this.selectedSegmentIndices = new Set(path.selected.length ? path.selected : [0]);
          this.setPaperPathData(path.pathData, 'path-restore');
          this.pathHistory = path.history.slice();
          this.pathRedo = path.redo.slice();
          host.dataset.vectorPathUndoDepth = String(this.pathHistory.length);
          host.dataset.vectorPathRedoDepth = String(this.pathRedo.length);
        }
        if (path) this.editablePathObject = path.editable;
        canvas.renderAll();
        this.syncSelection();
        if (typeof this.syncPathOverlay === 'function') this.syncPathOverlay();
      } finally {
        this.applyingSnapshot = false;
      }
      return true;
    },
    // A change the editor refuses at the act (a workspace read-only for
    // source changes) is taken back to the last accepted canvas, without
    // going through a tool (a shape tool's setTool adds a shape) and
    // without recording a source change, so a refusal cannot cause another.
    restoreAccepted() {
      if (!this.applySnapshot(this.acceptedSnapshot)) return false;
      host.dataset.vectorRestoredCount = String((Number(host.dataset.vectorRestoredCount) || 0) + 1);
      return true;
    },
    // The editor's undo or redo of a vector edit: the canvas shows what was
    // accepted with the entry now on top of the vector history, recording no
    // source change (the undo or redo stages its own). An entry this canvas
    // did not accept (one made before it was mounted) changes nothing.
    showHistory(historyId) {
      if (this.shownHistoryId === undefined) {
        this.shownHistoryId = historyId;
        if (this.acceptedSnapshot) this.historySnapshots.set(historyId, this.acceptedSnapshot);
        return false;
      }
      if (historyId === this.shownHistoryId) return false;
      const snapshot = this.historySnapshots.get(historyId);
      if (!snapshot || !this.applySnapshot(snapshot)) return false;
      this.acceptedSnapshot = snapshot;
      this.shownHistoryId = historyId;
      host.dataset.vectorHistoryShown = String(historyId);
      return true;
    },
    // A move, resize, rotation or skew of canvas objects with the Select
    // tool (fabric fires `object:modified` once, at the release, for the
    // object or the multi-selection it transformed), or a canvas text edit:
    // one source change. A transform of the editable path's shape moves the
    // Paper.js path with it, so the next node edit starts where the shape
    // is; that is still one change, not a node edit as well.
    cancelTransform() {
      const transform = canvas._currentTransform;
      if (!transform || !transform.target) return false;
      const target = transform.target;
      // fabric keeps the object's transform from before the drag in
      // `transform.original`, but its originX/originY there are the
      // transform's anchor -- the opposite corner or side of a resize or
      // skew -- not the object's own origin, so they are left out: set
      // back, they would displace the object.
      const { originX, originY, ...original } = transform.original;
      target.set(original);
      target.setCoords();
      target.isMoving = false;
      canvas._currentTransform = null;
      canvas.requestRenderAll();
      this.syncSelection();
      host.dataset.vectorGestureCancelled = 'transform';
      return true;
    },
    cancelStroke() {
      if (!canvas.isDrawingMode || !canvas._isCurrentlyDrawing) return false;
      canvas._isCurrentlyDrawing = false;
      const brush = canvas.freeDrawingBrush;
      if (brush && typeof brush._reset === 'function') brush._reset();
      canvas.clearContext(canvas.contextTop);
      canvas.requestRenderAll();
      host.dataset.vectorGestureCancelled = 'stroke';
      return true;
    },
    recordObjectModification(event) {
      if (this.applyingSnapshot) return false;
      const target = event && event.target;
      if (!target) return false;
      const members = target instanceof fabricLib.ActiveSelection ? target.getObjects() : [target];
      if (this.editablePathObject && members.includes(this.editablePathObject)) {
        this.releasingSelection(() => this.foldEditablePathTransform());
      }
      const action = (event.action || (event.transform && event.transform.action)) || 'modify';
      host.dataset.vectorModifiedAction = action;
      this.recordSourceChange(`object-${action}`);
      return true;
    },
    foldEditablePathTransform() {
      const obj = this.editablePathObject;
      if (!obj || !this.paperPath || !Array.isArray(obj.path)) return false;
      const util = fabricLib.util;
      const data = util.joinPath(util.transformPath(obj.path, obj.calcTransformMatrix(), obj.pathOffset));
      this.pushPathHistory();
      if (!this.setPaperPathData(data, 'path-transform')) return false;
      this.syncPathOverlay();
      return true;
    },
    recordSourceChange(operation) {
      const exported = this.sourceSvg();
      this.sourceChangeSeq += 1;
      host.dataset.vectorSourceDirty = 'true';
      host.dataset.vectorSourcePending = String(this.sourceChangeSeq);
      host.dataset.vectorSourceOperation = operation;
      host.dataset.vectorSourceLength = String(exported.length);
      globalThis.__isonimDeferView(host, () => {
        host.dispatchEvent(new CustomEvent('isonim-vector-source-change', {
          bubbles: true,
          detail: { operation, length: exported.length }
        }));
      }, 0);
      return exported;
    },
    setTool(nextTool) {
      host.dataset.vectorTool = nextTool;
      canvas.isDrawingMode = nextTool === 'pencil';
      // fabric 7 has no brush until one is set: without it the Pencil tool
      // drew nothing. PencilBrush smooths the stroke (quadratic segments
      // through decimated points).
      if (nextTool === 'pencil' && fabricLib.PencilBrush &&
          !(canvas.freeDrawingBrush instanceof fabricLib.PencilBrush)) {
        const brush = new fabricLib.PencilBrush(canvas);
        brush.color = '#F8FAFC';
        brush.width = 3;
        brush.decimate = 2;
        canvas.freeDrawingBrush = brush;
      }
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
      if (typeof this.syncPathOverlay === 'function') this.syncPathOverlay();
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
        if (host.__isonimViewDisposed) return;
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
        if (options.accept) this.acceptCurrent();
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
    },
    sourceSvg() {
      const exported = canvas.toSVG();
      host.dataset.vectorSvgLength = String(exported.length);
      host.dataset.vectorExportHasSvg = exported.includes('<svg') ? 'true' : 'false';
      return exported;
    }
  };
  host.__isonimVectorEditor = state;
  globalThis.__isonimVectorEditor = state;
  globalThis.__isonimViewCleanup(host, () => {
    if (globalThis.__isonimVectorEditor === state) delete globalThis.__isonimVectorEditor;
    delete host.__isonimVectorEditor;
    canvas.dispose();
  });

  canvas.on('selection:created', () => state.syncSelection());
  canvas.on('selection:updated', () => state.syncSelection());
  canvas.on('selection:cleared', () => state.syncSelection());
  // Recorded once fabric has finished the transform: releasing a
  // multi-selection while fabric still holds it as the current transform
  // would end that transform again, and fire this event again.
  canvas.on('object:modified', (event) => {
    state.syncSelection();
    globalThis.__isonimDeferView(host, () => state.recordObjectModification(event), 0);
  });
  canvas.on('object:added', () => state.syncSelection());
  // A Pencil stroke, added once the pointer is released: one source change.
  canvas.on('path:created', (event) => {
    const stroke = event && event.path;
    if (!stroke || state.applyingSnapshot) return;
    stroke.set({ name: 'drawn-pencil', selectable: true });
    state.syncSelection();
    state.recordSourceChange('pencil-stroke');
  });
  canvas.on('object:removed', () => state.syncSelection());
  // A Select-tool drag (move, resize, rotation, skew) or a Pencil stroke
  // in progress ends without an edit on Escape or pointer cancellation,
  // and the canvas goes back to what it showed before the drag (the
  // editor's drag contract). fabric does not cancel either itself.
  const cancelCanvasGesture = (event) => {
    const cancelled = state.cancelTransform() || state.cancelStroke();
    if (cancelled && event) {
      event.preventDefault();
      event.stopPropagation();
    }
    return cancelled;
  };
  const cancelOnEscape = (event) => {
    if (event.key === 'Escape') cancelCanvasGesture(event);
  };
  const cancelOnPointerCancel = (event) => { cancelCanvasGesture(null); };
  document.addEventListener('keydown', cancelOnEscape, true);
  document.addEventListener('pointercancel', cancelOnPointerCancel, true);
  globalThis.__isonimViewCleanup(host, () => {
    document.removeEventListener('keydown', cancelOnEscape, true);
    document.removeEventListener('pointercancel', cancelOnPointerCancel, true);
  });
  host.addEventListener('keydown', (event) => {
    if (event.key === 'Delete' || event.key === 'Backspace') {
      if (state.selectedPathNodes().length > 0) state.deleteSelectedPathNode();
      else state.deleteSelected();
      event.preventDefault();
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'd') {
      state.duplicateSelected();
      event.preventDefault();
    } else if (event.key.toLowerCase() === 'g') {
      state.groupSelected();
      event.preventDefault();
    } else if (event.key === 'ArrowRight') {
      state.nudgeSelectedPathNodes(event.shiftKey ? 8 : 1, 0);
      event.preventDefault();
    } else if (event.key === 'ArrowLeft') {
      state.nudgeSelectedPathNodes(event.shiftKey ? -8 : -1, 0);
      event.preventDefault();
    } else if (event.key === 'ArrowDown') {
      state.nudgeSelectedPathNodes(0, event.shiftKey ? 8 : 1);
      event.preventDefault();
    } else if (event.key === 'ArrowUp') {
      state.nudgeSelectedPathNodes(0, event.shiftKey ? -8 : -1);
      event.preventDefault();
    }
  });
  state.initEditablePath();
  // The loaded symbol is the first accepted canvas (taken again once the
  // asynchronous import has added its objects).
  state.acceptCurrent();
  state.importSvg(initialSvg, { silent: true, accept: true });
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
  if (action === 'path-insert') editor.insertPathNode();
  if (action === 'path-delete-node') editor.deleteSelectedPathNode();
  if (action === 'path-convert-smooth') editor.convertSelectedPathNode('smooth');
  if (action === 'path-handle-drag') editor.dragSelectedPathHandle(24, -18);
  if (action === 'path-nudge-right') editor.nudgeSelectedPathNodes(4, 0);
  if (action === 'path-undo') editor.undoPathOperation();
  if (action === 'path-redo') editor.redoPathOperation();
})()
  """].}

proc acceptFabricVectorEdits*[E](host: E; historyId = -1) =
  ## The canvas as it is now is what the editor accepted, with the vector
  ## history entry `historyId` (none: the loaded symbol).
  {.emit: ["""
(() => {
  const editor = """, host, """ && """, host, """.__isonimVectorEditor;
  if (editor) editor.acceptCurrent(""", historyId, """);
})()
  """].}

proc showFabricVectorHistory*[E](host: E; historyId: int) =
  ## The editor's vector history has the entry `historyId` on top (0: none):
  ## show the canvas accepted with it, recording no source change.
  {.emit: ["""
(() => {
  const editor = """, host, """ && """, host, """.__isonimVectorEditor;
  if (editor) editor.showHistory(""", historyId, """);
})()
  """].}

proc restoreFabricVectorEdits*[E](host: E) =
  ## Take a refused change off the canvas: back to the last accepted canvas,
  ## recording no source change.
  {.emit: ["""
(() => {
  const editor = """, host, """ && """, host, """.__isonimVectorEditor;
  if (editor) editor.restoreAccepted();
})()
  """].}

proc currentFabricVectorSvg*[E](host: E): string =
  var exported: cstring
  {.emit: [exported, " = (() => { const editor = ", host,
    " && ", host, ".__isonimVectorEditor; return editor ? editor.sourceSvg() : ''; })();"].}
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
