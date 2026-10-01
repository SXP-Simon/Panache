<template>
    <div id='text_file_select' class="d-flex justify-content-between">
        <div class="d-flex justify-content-between align-items-center mb-1">
            <label class="text-field-label m-0" for="textArea">{{ $t('message.text') }}:</label>
            <button 
                type="button"
                class="btn-latex-convert"
                data-testid="convert-latex-btn"
                :title="$t('message.convertLatex')"
                @click="convertLatex">
                <svg class="latex-icon" width="13" height="13" viewBox="0 0 16 16" fill="currentColor">
                    <path d="M4 2.5a.5.5 0 0 1 .5-.5h7a.5.5 0 0 1 0 1H6.207l4.147 4.146a.5.5 0 0 1 0 .708L6.207 12H11.5a.5.5 0 0 1 0 1h-7a.5.5 0 0 1-.354-.854L8.793 7.5 4.146 2.854A.5.5 0 0 1 4 2.5z"/>
                </svg>
                <span>{{ $t('message.convertLatex') }}</span>
            </button>
        </div>
        <textarea id="textArea" class="form-control" v-model="text" data-testid="text-input" @input="handleManualInput"
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

export default {
    name: 'TextInput',
    emits: ['childEvent', 'manual-input'],

    computed: {
        isLatexPresent() {
            return hasLatexMarkup(this.text);
        },
    },

    data() {
        return {
            text: '',
            isLoading: false,
            selectedTextFileName: '',
            quickSymbols: ['⇒', '→', '∈', 'Σ', 'α', 'β', 'π', '²', '³', '√', '≤', '≥', '≠', '|'],
        };
    },
    //当输入框的值发生变化时，通知HomeView更新text_handwriting 7.4
    watch: {
        text: function (val) {
            this.$emit('childEvent', val);
        }
    },
    created() {
        const localStorageItems = ['selectedTextFileName','text']
        localStorageItems.forEach(item => {
            const value = localStorage.getItem(item);
            if (value !== null && value !== "undefined") {
                this[item] = JSON.parse(value);
            } else {
                console.log('localstorage缺失item:' + item)
            }
        });
    },
    methods: {
        handleManualInput() {
            this.$emit('manual-input');
        },
        convertLatex() {
            if (!this.text) return;
            const converted = convertLatexToUnicode(this.text);
            this.replaceText(converted);
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

.btn-latex-convert {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 10px;
    font-size: 0.8rem;
    font-family: inherit;
    color: #007BFF;
    background-color: #ffffff;
    border: 1px solid #ced4da;
    border-radius: 5px;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
    cursor: pointer;
    transition: all 0.2s ease;
}

.btn-latex-convert:hover {
    color: #0056b3;
    background-color: #e3f2fd;
    border-color: #007BFF;
}

.btn-latex-convert:active {
    color: #003d73;
    background-color: #bbdefb;
    transform: scale(0.98);
}

.latex-icon {
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
</style>
