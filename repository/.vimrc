colors murphy
syntax on
set nowrap
" use only Spaces
set expandtab
" indent with two spaces
set tabstop=2
set shiftwidth=2
" nativ indent detection
set autoindent
set smartindent
" activate language detection
filetype plugin indent on

nmap <F1> <Esc>:w<CR>:!clear;lua %<CR>

