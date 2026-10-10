<template>
    <div id='text_file_select' class="d-flex justify-content-between" @keydown="handleContainerKeyDown">
        <div class="d-flex justify-content-between align-items-center mb-1 flex-wrap gap-1">
            <label class="text-field-label m-0" for="textArea">{{ $t('message.text') }}:</label>
            <div class="text-tools-group d-flex gap-2 align-items-center">
                <div class="table-mode-wrap d-flex align-items-center gap-1">
                    <span class="text-muted small table-mode-label">表格处理:</span>
                    <select 
                        v-model="tableMode" 
                        class="form-select form-select-sm table-mode-select" 
                        data-testid="table-mode-select"
                        :title="$t('message.tableMode')">
                        <option value="list">{{ $t('message.tableModeList') }}</option>
                        <option value="aligned">{{ $t('message.tableModeAligned') }}</option>
                        <option value="raw_pipe">{{ $t('message.tableModeRawPipe') }}</option>
                    </select>
                </div>
                <button 
                    type="button"
                    class="btn-text-tool"
                    data-testid="clean-markdown-btn"
                    :title="$t('message.cleanMarkdown')"
                    @click="cleanMarkdownText">
                    <svg class="tool-icon" width="13" height="13" viewBox="0 0 16 16" fill="currentColor">
                        <path d="M14.06 3.054a1.5 1.5 0 0 0-2.122 0l-.707.707 2.122 2.122.707-.707a1.5 1.5 0 0 0 0-2.122zM10.525 4.468 2.614 12.38a1.5 1.5 0 0 0-.41.74l-.64 2.56a.5.5 0 0 0 .606.606l2.56-.64a1.5 1.5 0 0 0 .74-.41l7.91-7.91-2.855-2.858z"/>
                    </svg>
                    <span>{{ $t('message.cleanMarkdown') }}</span>
                </button>
                <button 
                    type="button"
                    class="btn-text-tool"
                    data-testid="convert-latex-btn"
                    :title="$t('message.convertLatex')"
                    @click="convertLatex">
                    <svg class="tool-icon" width="13" height="13" viewBox="0 0 16 16" fill="currentColor">
                        <path d="M4 2.5a.5.5 0 0 1 .5-.5h7a.5.5 0 0 1 0 1H6.207l4.147 4.146a.5.5 0 0 1 0 .708L6.207 12H11.5a.5.5 0 0 1 0 1h-7a.5.5 0 0 1-.354-.854L8.793 7.5 4.146 2.854A.5.5 0 0 1 4 2.5z"/>
                    </svg>
                    <span>{{ $t('message.convertLatex') }}</span>
                </button>
            </div>
        </div>
        <textarea id="textArea" class="form-control" v-model="text" data-testid="text-input" 
            @input="handleManualInput"
            @keydown="handleTextareaKeyDown"
            @paste="handlePaste"
            ref="textAreaRef"
            :aria-label="$t('message.text')" :placeholder="$t('message.enterText')"></textarea>

        <!-- 常用数学符号快捷栏 -->
        <div class="math-quick-bar">
            <span class="math-quick-label">{{ $t('message.mathSymbolsTitle') }}:</span>
            <div class="math-chips-container">
                <button 
                    v-for="sym in quickSymbols" 
                    :key="sym" 
                    type="button" 
                    class="math-chip-btn" 
                    @click="insertSymbol(sym)"
                    :title="sym">
                    {{ sym }}
                </button>
            </div>
        </div>

        <!-- 已插入插图缩略图列表栏 -->
        <div v-if="referencedImages.length > 0" class="inline-images-toolbar d-flex flex-wrap align-items-center gap-2 mt-2 mb-2 p-2 bg-light rounded border" data-testid="inline-images-bar">
            <span class="inline-images-label small text-muted d-flex align-items-center gap-1">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
                    <path d="M6.002 5.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0z"/>
                    <path d="M2.002 1a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2h-12zm12 1a1 1 0 0 1 1 1v6.5l-3.777-1.947a.5.5 0 0 0-.577.093l-3.71 3.71-2.66-1.772a.5.5 0 0 0-.63.062L1.002 12V3a1 1 0 0 1 1-1h12z"/>
                </svg>
                {{ $t('message.inlineImagesTitle') }} ({{ referencedImages.length }}):
            </span>
            <div 
                v-for="img in referencedImages" 
                :key="img.id" 
                class="inline-img-card badge bg-white text-dark border d-flex align-items-center gap-2 p-1 pe-2 shadow-sm"
                :title="img.alt">
                <img :src="img.data" class="inline-img-thumbnail" :alt="img.alt" />
                <span class="inline-img-tag font-monospace">{{ img.alt }}</span>
                <button 
                    type="button" 
                    class="btn-inline-img-remove" 
                    :title="$t('message.delete')" 
                    @click="removeInlineImage(img.id, img.index)">
                    &times;
                </button>
            </div>
        </div>

        <label for="textFileInput">{{ $t('message.orUploadDocument') }}:</label>
        <div class="file_select_container">
            <button @click="triggerTextFileInput" data-testid="text-file-btn">{{ $t('message.chooseFile') }}</button>
            <span class="border p-2 text-primary " v-if="selectedTextFileName"
                data-testid="text-file-name">{{ selectedTextFileName }}</span>
            <label>
                <input type="file" ref="textFileInput" @change="uploadFile" id="textFileInput" data-testid="text-file-input"
                    accept=".doc,.docx,.pdf,.txt,.rtf" style="display: none;" />
            </label>
        </div>

        <div v-if="isLoading" class="loader">{{ $t('message.loading') }}...</div>
    </div>
</template>


<script>
import { convertLatexToUnicode, hasLatexMarkup } from '@/utils/latexToUnicode';
import { cleanMarkdown, hasMarkdownMarkup } from '@/utils/cleanMarkdown';
import { collapseInlineImages, expandInlineImages, getReferencedImages } from '@/utils/inlineImageManager';

export default {
    name: 'TextInput',
    emits: ['childEvent', 'manual-input'],

    computed: {
        isLatexPresent() {
            return hasLatexMarkup(this.text);
        },
        isMarkdownPresent() {
            return hasMarkdownMarkup(this.text);
        },
        referencedImages() {
            return getReferencedImages(this.text, this.inlineImageStore);
        },
    },

    data() {
        return {
            text: '',
            isLoading: false,
            selectedTextFileName: '',
            tableMode: 'list', // 'list' | 'aligned' | 'raw_pipe'
            quickSymbols: ['⇒', '→', '∈', 'Σ', 'α', 'β', 'π', '²', '³', '√', '≤', '≥', '≠', '|'],
            inlineImageStore: {},
        };
    },
    //当输入框的值发生变化时，通知HomeView更新text_handwriting 7.4
    watch: {
        text: function (val) {
            if (val && val.includes('data:image/')) {
                const { collapsedText, imageStore } = collapseInlineImages(val, this.inlineImageStore);
                this.inlineImageStore = imageStore;
                this.text = collapsedText;
                return;
            }
            this.emitExpandedText();
        },
        tableMode: function (val) {
            localStorage.setItem('markdownTableMode', JSON.stringify(val));
        }
    },
    created() {
        const localStorageItems = ['selectedTextFileName','text'];
        localStorageItems.forEach(item => {
            const value = localStorage.getItem(item);
            if (value !== null && value !== "undefined") {
                this[item] = JSON.parse(value);
            } else {
                console.log('localstorage缺失item:' + item);
            }
        });
        if (this.text && this.text.includes('data:image/')) {
            const { collapsedText, imageStore } = collapseInlineImages(this.text, this.inlineImageStore);
            this.text = collapsedText;
            this.inlineImageStore = imageStore;
        }
        const savedTableMode = localStorage.getItem('markdownTableMode');
        if (savedTableMode) {
            try {
                this.tableMode = JSON.parse(savedTableMode);
            } catch (e) {
                this.tableMode = 'list';
            }
        }
    },
    methods: {
        emitExpandedText() {
            const fullText = expandInlineImages(this.text, this.inlineImageStore);
            this.$emit('childEvent', fullText);
            localStorage.setItem('text', JSON.stringify(fullText));
        },
        handleManualInput() {
            this.$emit('manual-input');
        },
        handlePaste(e) {
            const clipboardData = e.clipboardData || window.clipboardData;
            if (!clipboardData || !clipboardData.items) return;

            const items = clipboardData.items;
            for (let i = 0; i < items.length; i++) {
                if (items[i].type.indexOf('image') !== -1) {
                    const file = items[i].getAsFile();
                    if (file) {
                        e.preventDefault();
                        const reader = new FileReader();
                        reader.onload = (uploadEvent) => {
                            const base64Data = uploadEvent.target.result;
                            const nextIdx = Object.keys(this.inlineImageStore).length + 1;
                            const id = `img_${nextIdx}`;
                            this.inlineImageStore[id] = base64Data;
                            const imageMarker = `\n![插图 ${nextIdx}]\n`;
                            this.insertSymbol(imageMarker);
                        };
                        reader.readAsDataURL(file);
                        break;
                    }
                }
            }
        },
        removeInlineImage(id, index) {
            delete this.inlineImageStore[id];
            const regex = new RegExp(`!\\[(插图[ \\t]*[#:_-]?[ \\t]*${index}|[^\\]]*\\(img:?_?${index}\\))\\]`, 'g');
            this.text = this.text.replace(regex, '');
            this.emitExpandedText();
        },
        handleTextareaKeyDown(e) {
            // 当在输入框中按下 Ctrl+A (或 Mac 下 Cmd+A) 时，精准全选输入框内文本并阻止事件冒泡扩散到全页
            if ((e.ctrlKey || e.metaKey) && (e.key === 'a' || e.key === 'A' || e.keyCode === 65)) {
                e.stopPropagation();
                const textarea = this.$refs.textAreaRef;
                if (textarea) {
                    textarea.focus();
                    textarea.setSelectionRange(0, textarea.value.length);
                }
            }
        },
        handleContainerKeyDown(e) {
            // 当焦点位于文字栏容器内按 Ctrl+A 时，阻止全局选区泄露并将选区锁定在当前输入框
            if ((e.ctrlKey || e.metaKey) && (e.key === 'a' || e.key === 'A' || e.keyCode === 65)) {
                if (e.target && e.target.tagName === 'INPUT') {
                    return;
                }
                e.preventDefault();
                e.stopPropagation();
                const textarea = this.$refs.textAreaRef;
                if (textarea) {
                    textarea.focus();
                    textarea.setSelectionRange(0, textarea.value.length);
                }
            }
        },
        cleanMarkdownText() {
            if (!this.text) return;
            const cleaned = cleanMarkdown(this.text, { tableMode: this.tableMode });
            this.replaceText(cleaned);
            this.$emit('manual-input');
            this.$emit('childEvent', this.text);
        },
        convertLatex() {
            if (!this.text) return;
            const converted = convertLatexToUnicode(this.text);
            this.replaceText(converted);
            this.$emit('manual-input');
            this.$emit('childEvent', this.text);
        },
        insertSymbol(sym) {
            const textarea = this.$refs.textAreaRef;
            if (!textarea) {
                this.text += sym;
                return;
            }
            const start = textarea.selectionStart || this.text.length;
            const end = textarea.selectionEnd || this.text.length;
            const before = this.text.substring(0, start);
            const after = this.text.substring(end);
            this.text = before + sym + after;
            this.$emit('manual-input');
            this.$emit('childEvent', this.text);
            this.$nextTick(() => {
                textarea.focus();
                textarea.setSelectionRange(start + sym.length, start + sym.length);
            });
        },
        replaceText(value) {
            this.text = typeof value === 'string' ? value : '';
            localStorage.setItem('text', JSON.stringify(this.text));
        },
        uploadFile(e) {
            let file = e.target.files[0];
            this.$emit('manual-input');
            // 当用户选择了一个新的文本文件时，更新 selectedTextFileName
            this.selectedTextFileName = e.target.files[0].name;
            // localStorage.setItem('textFile', JSON.stringify(this.textFile));
            localStorage.setItem('selectedTextFileName', JSON.stringify(this.selectedTextFileName));

            let formData = new FormData();

            formData.append('file', file);  // 'file' 是你在服务器端获取文件数据时的 key
            this.isLoading = true;
            this.$http.post(
                '/api/textfileprocess',
                formData, {

                headers: {
                    'Content-Type': 'multipart/form-data'
                }
            })
                .then(response => {
                    this.text = response.data.text;
                    //通知HomeView更新text 7.3, 但是如果直接输入文字，这里不会通知父组件7.4
                    this.$emit('childEvent', this.text);
                    // 使用与 HomeView 一致的键名存储
                    localStorage.setItem('text', JSON.stringify(this.text));
                    // 切换新旧版布局会重建本组件：上传途中被重建时上面的 $emit 会被 Vue 丢弃
                    //（实例已卸载），所以再广播一次，让 HomeView 把结果交给当前活着的输入框
                    window.dispatchEvent(new CustomEvent('handwriting-text-loaded', { detail: this.text }));
                    this.isLoading = false;
                })
                .catch(error => {
                    console.error(error);
                    this.isLoading = false;
                });
        },
        triggerTextFileInput() {
            this.$refs.textFileInput.click();
        },
    },

}
</script>

<style scoped>
#text_file_select {
    position: relative;
    /* 设置父元素为相对定位 */
    display: flex;
    flex-direction: column;
    gap: 10px;
    max-width: 400px;
    margin: auto;
}


#text_file_select label {
    font-size: 1.1rem;
    font-weight: 500;
}

#text_file_select span {
    display: block;
    margin-left: 10px;
    margin-top: 5px;
    font-size: 0.9rem;
    color: #444;
}

.file_select_container {
    display: flex;
    /* gap: 10px; */
    align-items: center;
}

.file_select_container button {
    padding: 10px 10px;
    font-size: 0.9rem;
    color: white;
    background-color: #4285f4;
    border: none;
    border-radius: 5px;
    cursor: pointer;
}

.file_select_container button:disabled {
    background-color: grey;
}

.file_select_container span{
    font-size: 0.9rem;
}

.loader {
    border: 16px solid #f3f3f3;
    /* Light grey */
    border-top: 16px solid #3498db;
    /* Blue */
    border-radius: 50%;
    width: 120px;
    height: 120px;
    animation: spin 2s linear infinite;
    position: absolute;
    /* 设置动画为绝对定位 */
    top: 50%;
    /* 将动画定位在父元素的中心 */
    left: 50%;
    transform: translate(-50%, -50%);
    /* 用 transform 属性将动画元素的中心对准父元素的中心 */
}

@keyframes spin {
    0% {
        transform: rotate(0deg);
    }

    100% {
        transform: rotate(360deg);
    }
}

.text-tools-group {
    display: flex;
    align-items: center;
    gap: 6px;
}

.table-mode-wrap {
    display: flex;
    align-items: center;
    gap: 4px;
}

.table-mode-label {
    font-size: 0.76rem;
    white-space: nowrap;
}

.table-mode-select {
    padding: 2px 24px 2px 8px;
    font-size: 0.78rem;
    height: 28px;
    width: auto;
    min-width: 140px;
    max-width: 165px;
    border-radius: 5px;
    border-color: #ced4da;
    color: #495057;
    background-color: #fff;
    cursor: pointer;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
}

.table-mode-select:focus {
    border-color: #007BFF;
    outline: none;
    box-shadow: 0 0 0 0.15rem rgba(0, 123, 255, 0.25);
}

.btn-text-tool {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    font-size: 0.78rem;
    font-family: inherit;
    color: #007BFF;
    background-color: #ffffff;
    border: 1px solid #ced4da;
    border-radius: 5px;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
    cursor: pointer;
    transition: all 0.2s ease;
}

.btn-text-tool:hover {
    color: #0056b3;
    background-color: #e3f2fd;
    border-color: #007BFF;
}

.btn-text-tool:active {
    color: #003d73;
    background-color: #bbdefb;
    transform: scale(0.98);
}

.tool-icon {
    flex-shrink: 0;
}

.math-quick-bar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px;
    padding: 6px 8px;
    background: #ffffff;
    border: 1px solid #e9ecef;
    border-radius: 5px;
    font-size: 0.8rem;
}

.math-quick-label {
    font-size: 0.75rem !important;
    color: #6c757d;
    margin: 0 !important;
    white-space: nowrap;
}

.math-chips-container {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
}

.math-chip-btn {
    padding: 1px 7px;
    font-size: 0.82rem;
    font-family: inherit;
    color: #495057;
    background: #f8f9fa;
    border: 1px solid #dee2e6;
    border-radius: 4px;
    cursor: pointer;
    line-height: 1.35;
    transition: all 0.15s ease;
}

.math-chip-btn:hover {
    background-color: #007BFF;
    color: #ffffff;
    border-color: #007BFF;
}

.math-chip-btn:active {
    background-color: #0056b3;
    border-color: #0056b3;
}

.inline-images-toolbar {
    background: #fdfdfd;
    border-color: #e2e8f0 !important;
}

.inline-images-label {
    font-size: 0.76rem !important;
    font-weight: 500;
}

.inline-img-card {
    display: inline-flex;
    align-items: center;
    background: #ffffff;
    border: 1px solid #ced4da !important;
    border-radius: 4px;
    padding: 2px 6px 2px 4px !important;
    font-size: 0.78rem;
    color: #333;
    transition: all 0.15s ease;
}

.inline-img-card:hover {
    border-color: #007BFF !important;
    box-shadow: 0 2px 4px rgba(0, 123, 255, 0.12) !important;
}

.inline-img-thumbnail {
    width: 24px;
    height: 24px;
    object-fit: cover;
    border-radius: 3px;
    border: 1px solid #e9ecef;
}

.inline-img-tag {
    font-size: 0.76rem;
    color: #495057;
}

.btn-inline-img-remove {
    background: transparent;
    border: none;
    color: #dc3545;
    font-size: 14px;
    line-height: 1;
    padding: 0 2px;
    cursor: pointer;
    border-radius: 2px;
    transition: all 0.1s;
}

.btn-inline-img-remove:hover {
    background-color: #fee2e2;
    color: #b91c1c;
}

#textArea {
    user-select: text;
    -webkit-user-select: text;
}

.text-tools-group,
.math-quick-bar,
.inline-images-toolbar,
.file_select_container {
    user-select: none;
    -webkit-user-select: none;
}
</style>
